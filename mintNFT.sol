// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "./governance.sol";
import "./getTokenByUniswap.sol";

/*
    --------------------------------------------------------------------------------
    보험 가입자가 토큰 20개를 들고있거나, 조만간 20개를 사서 투자하고 싶음. 현재 20개의 토큰 가치는 200불이다.
    그런데, 그냥 현물 투자를 하기엔 너무 리스크가 큼. 가격이 20% 정도 하락할 수도 있다는 생각을 하고 보험 가입 서비스를 이용하러 옴.

    1. 20개의 토큰가치인 200불(200 usdt) 을 갖고있는지 확인.
    2. 200불의 20% 를 커버 보험 가입으로 사용.
    3. (40불 * 기간별, 토큰별 보혐료율) 적용 한 금액을 보험료로 납부, NFT 를 민팅함
    4. 얼마 후, 민팅 시의 가격에서 20% 하락. 보험금 청구하러 옴
    5. 청구할 때, 필요한 정보들 => 기간, 토큰타입(가격확인), 얼마만큼의 보험금을 청구할지
    
    프론트 : 얼마 만큼의 토큰을 커버할건지 확인함 => uniswap 풀 가격 가져와서 현재 토큰의 가격을 프론트에 띄워줌
    위에서 받은 1토큰당 가격에, 커버할 토큰 갯수를 사용자가 입력, mintNFT 함수에 인자로 들어갈 _amount(가격 x 토큰) 값이 나옴.
    예를 들어, 토큰 20개 x 10불 = 200불의 _amount 값을 설정.
    사용자는 몇% 하락했을 때, 보험금을 지급받을 지 결정하고, 정수단위(15,45,50..)를 _coverRatio 인자로 넣음.
    20을 입력했다면, 200불의 20% 인 40불에 기간별, 토큰별 보혐료율을 곱해서 지불할 금액으로 띄워주고 approve 시키고 민팅
    
    컨트랙트 : 200불의 _amount, 20의 _coverRatio 를 설정하고 민팅을 눌렀다.
    40불의 토큰을 전송받아서 insurPool 주소로 넘기고 NFT 민팅해줌.
    토큰의 가격이 20% 하락할 경우, NFT 보유자가 보험금 받으러 옴.
    Claim 로직에서는, 아래 3가지 사항을 확인.
    1. 토큰의 주인인가? (ownerOf 확인)
    2. 유효한가? (기간, 이미 청구했는지)(term, minttime, isActive 확인)
    3. 토큰의 가격이 20% 만큼 하락했는가? (ratio, type 확인)
    확인 후 coverAmount * ratio 만큼을 msg.sender 에게 지급함.
    --------------------------------------------------------------------------------
    보험료 계산 (nexus mutual) => 사실상 운영팀이 알아서 결정함.
    ***보험료 = bumpedPrice - priceDrop 
    ***bumpedPrice = spotPrice + capacity% of the pool to be used / 1% x 0.2
    ***bumpedPrice = 0.5% + 1% = 1.5%
    ***priceDrop = timeSinceLastCoverBuy * speed
    ***priceDrop = 0.5 days * 0.5% = 0.25%

    * 토큰마다 보험료를 다르게 적용함. (wETH + 0%, UNI + 10%)
    ** 사용자가 지정한 하락률마다 보험료를 적용함 ( 30일 10~15% 구간 할증, 365일 10~20% 구간 할증 )
    --------------------------------------------------------------------------------
*/

contract Mint721Token is ERC721URIStorage, ERC2981 {
    governance governances;
    getBalance getWETHBalance;
    getBalance getUNIBalance;

    struct NFT_Data {
        uint8 coverTerm; // 0 : 30일, 1: 365일
        uint8 tokenType; // 0 : wETH, 1 : UNI
        uint coverRatio; // 10~90% , 하락한 만큼 보험금 지급
        uint mintTime; // 보험 계약 시간
        uint tokenPrice; // 보험 계약(민팅) 당시의 토큰 가격 
        uint coverAmount; // 총 커버할 금액. 청구 가능 보험금 = coverAmount * coverRatio
        bool isActive; // true : 활성화, false : 비활성화
    }

    NFT_Data[] private NFT_Datas;
    ERC20 public token = ERC20(0x617489EDf1b0E9546D34aA50f22194F582E17f81); // test USDT CA
    // ERC20 public token_wETH = ERC20(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6); // test wETH CA (테스트 넷이므로 사용하지 않아 주석처리)
    // ERC20 public token_UNI = ERC20(0x1f9840a85d5af5bf1d1762f925bdaddc4201f984); // test UNI CA 0x1f9840a85d5af5bf1d1762f925bdaddc4201f984
    string public baseURI;
    address public insurPool;
    address public admin;
    uint public tokenId;

    mapping(address => uint) private totalSpend;
    
    uint16 priceFormula_30 = 125; // 수수료율 1.25% | daily 0.0416%
    uint16 priceFormula_365 = 760; // 수수료율 7.60% | daily 0.0208%
    uint8 priceDiscount = 10; // 가격 할인율. 5000불 이상 커버를 구매할때, 100불마다 0.001% 할인. ex) 15000불 구매시 0.1% 할인

    constructor(string memory _baseUri, address _insurPool, address _governance_address, address _admin) ERC721("InsurSand","IS"){
        getUNIBalance = getBalance(0x418b2be7F5ABE9a7104f503F8FCf25192A5e091f); // 토큰 가격 가져오기 위한 CA 설정
        getWETHBalance = getBalance(0x2F5136C8f0Bdf1DC797Cb52419D28143D6F72f93); // 토큰 가격 가져오기 위한 CA 설정
        baseURI = _baseUri;
        insurPool = _insurPool; // 보험 기금 풀
        governances = governance(_governance_address); // 거버넌스 투표 컨트랙트
        admin = _admin; // 수수료율을 관리할 어드민 지정
        _setDefaultRoyalty(_insurPool, 500); // 5% 로열티 설정. << OPENSEA 와 같은 사이트에서 인식함. 개인간 거래에선 적용 안됨.
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // wETH 가격 하락에 대한 커버를 민팅하는 함수 ( 30일 : _coverRatio 10~15% 구간, 365일은 10~20% 구간이 제일 비쌈 )
    function mintNFTCover_wETH(uint8 _coverTerm, uint8 _coverRatio, uint _amount, string memory _ipfsHash) public {
        require(_coverRatio >= 10 && _coverRatio <= 90,"Cover Ratio is available 10 to 90.");
        
        uint wETHFee = 100; // wETH 토큰의 가중치 1
        uint coverPrice = calculateCoverFee(_coverTerm, _coverRatio, _amount); // 커버 가격 계산
        coverPrice = coverPrice * wETHFee / 100;

        (uint token1, uint token2) = getWETHBalance.getPoolBalances(); // wETH 가격 계산 from uniswap
        uint currentTokenPrice = token1 / token2; // wETH 가격 = DAI 예치량 / WETH 예치량 | 1 wETH = 341,174 DAI

        // 보유한 wETH 의 평가액이 _amount 이상이면서 보유한 USDT 로 보험금 결제가 가능한지(테스트넷이므로 주석처리), 또는 USDT 보유량이 _amount 이상인지 확인.
        require(/*_amount <= token_wETH.balanceOf(msg.sender) * currentTokenPrice && coverPrice <= token.balanceOf(msg.sender) || */ 
        _amount <= token.balanceOf(msg.sender),"Insufficient balances.");
        require(coverPrice >= 1,"Invaild Cover Price");

        token.transferFrom(tx.origin, insurPool, coverPrice);
        totalSpend[msg.sender] += coverPrice;
        NFT_Datas.push(NFT_Data(_coverTerm, 0, _coverRatio, block.timestamp, currentTokenPrice, _amount, true)); // 중간에 코인 가격 받아와서 넣어야 함
        governances.increaseVotePower(calculateVotePower(coverPrice), msg.sender);

        _mint(msg.sender, tokenId);
        _setTokenURI(tokenId++, string(abi.encodePacked(baseURI, _ipfsHash)));
    }

    // UNI 가격 하락에 대한 커버를 민팅하는 함수
    function mintNFTCover_UNI(uint8 _coverTerm, uint8 _coverRatio, uint _amount, string memory _ipfsHash) public {
        require(_coverRatio >= 10 && _coverRatio <= 90,"Cover Ratio is available 10 to 90.");

        uint UNIFee = 110; // UNI 토큰의 가중치 10%
        uint coverPrice = calculateCoverFee(_coverTerm, _coverRatio, _amount); // 커버 가격 계산
        coverPrice = coverPrice * UNIFee / 100;

        (uint token1, uint token2) = getWETHBalance.getPoolBalances(); // UNI 가격 계산 from uniswap
        uint currentTokenPrice = token1 / token2; // UNI 가격 = DAI 예치량 / UNI 예치량 | 1 UNI = 32,964 DAI

        // 보유한 UNI 의 평가액이 _amount 이상이면서 보유한 USDT 로 보험금 결제가 가능한지(테스트넷이므로 주석처리), 또는 USDT 보유량이 _amount 이상인지 확인.
        require(/*_amount <= token_UNI.balanceOf(msg.sender) * currentTokenPrice && coverPrice <= token.balanceOf(msg.sender) || */ 
        _amount <= token.balanceOf(msg.sender),"Insufficient balances.");
        require(coverPrice >= 1,"Invaild Cover Price");

        token.transferFrom(tx.origin, insurPool, coverPrice);
        totalSpend[msg.sender] += coverPrice;
        NFT_Datas.push(NFT_Data(_coverTerm, 1, _coverRatio, block.timestamp, currentTokenPrice, _amount, true)); // 중간에 코인 가격 받아와서 넣어야 함
        governances.increaseVotePower(calculateVotePower(coverPrice), msg.sender);

        _mint(msg.sender, tokenId);
        _setTokenURI(tokenId++, string(abi.encodePacked(baseURI, _ipfsHash)));
    }

    // wETH 토큰 하락 보험금을 claim 하는 함수 (wETH, UNI 등. 모든 토큰이 이 함수를 사용해서 claim)
    function claimCover(uint _tokenId) public {
        require(_tokenId < tokenId,"Invaild tokenId");
        require(msg.sender == ownerOf(_tokenId),"You are Not Owner of NFT."); // msg.sender 가 NFT 를 보유중인지 확인

        // 30일 커버의 유효기간 확인
        if(NFT_Datas[_tokenId].coverTerm == 0){
            require(NFT_Datas[_tokenId].isActive == true &&
            NFT_Datas[_tokenId].mintTime + 2592000 > block.timestamp,"Your Cover expired.");

        } // 365일 커버의 유효기간 확인
        else if(NFT_Datas[_tokenId].coverTerm == 1){
            require(NFT_Datas[_tokenId].isActive == true && 
            NFT_Datas[_tokenId].mintTime + 31536000 > block.timestamp,"Your Cover expired.");
        }

        // wETH 의 claim 조건 확인 (현재 wETH 의 가격을 불러옴)
        if(NFT_Datas[_tokenId].tokenType == 0){
            (uint token1, uint token2) = getWETHBalance.getPoolBalances();
            uint currentTokenPrice = (token1 / token2) / 10; // claim 을 테스트하기 위해 /10
            require( NFT_Datas[_tokenId].tokenPrice - (NFT_Datas[_tokenId].tokenPrice * NFT_Datas[_tokenId].coverRatio / 100) >= currentTokenPrice
            ,"Your claim request is not Accepted. Check current token price first.");

        } // UNI 의 claim 조건 확인 (현재 UNI 의 가격을 불러옴)
        else if(NFT_Datas[_tokenId].tokenType == 1){
            (uint token1, uint token2) = getUNIBalance.getPoolBalances();
            uint currentTokenPrice = (token1 / token2) / 10; // claim 을 테스트하기 위해 /10
            require( NFT_Datas[_tokenId].tokenPrice - (NFT_Datas[_tokenId].tokenPrice * NFT_Datas[_tokenId].coverRatio / 100) >= currentTokenPrice
            ,"Your claim request is not Accepted. Check current token price first.");
        } else { // 다른 토큰의 커버는 미완성이므로 revert
            revert("It is the wrong approach.");
        }

        NFT_Datas[_tokenId].isActive = false;
        token.transfer(msg.sender, NFT_Datas[_tokenId].coverAmount * NFT_Datas[_tokenId].coverRatio / 100);
        // 여기에 NFT 이미지를 expired 로 변경하는 _setTokenURI(_tokenId, string(abi.encodePacked(baseURI, _ipfsHash))); 함수 넣기
    }

    // 커버 수수료 및 할인율 변경
    function setPriceFormula(uint8 _setFormula_30, uint16 _setFormula_365, uint8 _priceDiscount) public {
        require(msg.sender == admin,"Your are not admin");
        priceFormula_30 = _setFormula_30;
        priceFormula_365 = _setFormula_365;
        priceDiscount = _priceDiscount;
    }

    // 거버넌스 address 변경
    function setGovernanceAddress(address _addr) public {
        require(msg.sender == admin,"Admin only.");
        governances = governance(_addr);
    }

    // 총 커버 금액 (만료된 커버 포함)
    function getTotalCoverAmount() public view returns(uint){
        uint TotalCoverAmount;
        for(uint i; i < NFT_Datas.length; i++){
            TotalCoverAmount += NFT_Datas[i].coverAmount;
        }
        return TotalCoverAmount;
    }

    // 총 커버 금액 (만료된 커버 제외)
    function getTotalActiveCoverAmount() public view returns(uint){
        uint TotalActiveCoverAmount;
        for(uint i; i < NFT_Datas.length; i++){
            if(NFT_Datas[i].isActive == true){
                TotalActiveCoverAmount += NFT_Datas[i].coverAmount;
            }
        }
        return TotalActiveCoverAmount;
    }

    // 특정 tokenId 의 NFT Data 를 반환
    function getNFTDatas(uint _tokenId) public view returns(NFT_Data memory){
        require(msg.sender == ownerOf(_tokenId),"You are not owner of NFT.");
        return NFT_Datas[_tokenId];
    }
        
    // 보험 구매에 사용한 금액 총액
    function getTotalSpend(address _msgsender) public view returns(uint){
        return totalSpend[_msgsender];
    } 

    // 30일 커버의 보험비 계산
    function getCurrentFormula_30() public view returns(string memory){
        return Strings.toString(priceFormula_30);
    } 

    // 365일 커버의 보험비 계산
    function getCurrentFormula_365() public view returns(string memory){
        return Strings.toString(priceFormula_365);
    } 

    // 민팅 비용에 따른 투표권 지급을 계산하는 함수
    function calculateVotePower(uint _amount) public pure returns(uint){
        require(_amount > 0,"Cover Price is invaild.");
        if(_amount < 100){
            return 1;
        } else if(_amount <= 200){
            return 2;
        } else {
            return 3;
        }
    }

    // 5000불 이상의 할인율 계산 함수
    function getPercentage(uint _amount) public pure returns(uint) {
        uint percentage;
        if(_amount >= 5100){
            uint discount = _amount - 5000;
            percentage = discount / 100;
        } else {
            return 0;
        }
        return percentage;
    }

    // 보험료 계산 함수
    function calculateCoverFee(uint8 _coverTerm, uint8 _coverRatio, uint _amount) public view returns(uint){
        uint coverPrice; // 커버 구매 시 내야 할 금액
        uint RCVDAmount = _amount * _coverRatio / 100; // claim 시 받을 수 있는 금액

        // 커버기간 30일인 경우 10~15% 구간이 제일 비쌈
        if(_coverTerm == 0){
            if(_coverRatio < 16) {
                uint ratioWeight = 90 - _coverRatio; 
                coverPrice = (priceFormula_365 * 10 - getPercentage(RCVDAmount)) * ratioWeight * _amount * 625 / 10000000000;
            }
            else {
                uint ratioWeight = 90 - _coverRatio; 
                coverPrice = (priceFormula_30 * 10 - getPercentage(RCVDAmount)) * ratioWeight * _amount * 312 / 1000000000;
            }
        // 커버기간 365일인 경우 10~20% 구간이 제일 비쌈
        } else if(_coverTerm == 1){
                if(_coverRatio < 21) {
                uint ratioWeight = 90 - _coverRatio; 
                coverPrice = (priceFormula_30 * 10 - getPercentage(RCVDAmount)) * ratioWeight * _amount * 625 / 1000000000;
            }
            else {
                uint ratioWeight = 90 - _coverRatio; 
                coverPrice = (priceFormula_365 * 10 - getPercentage(RCVDAmount)) * ratioWeight * _amount * 312 / 10000000000;
            }
        } else {
            revert("It is wrong approach.");
        }
        return coverPrice;
    }

    // 특정 토큰에 대한 정보를 반환
    function getCoverAmount(uint _tokenId) public view returns(NFT_Data memory) {
        require(ownerOf(_tokenId) == msg.sender,"You are not owner of NFT.");
        return NFT_Datas[_tokenId];
    } 

    // 현재 wETH 가격 반환
    function getWETHBalances() public view returns(uint) {
        (uint token1, uint token2) = getWETHBalance.getPoolBalances();
        uint currentTokenPrice = token1 / token2;
        return currentTokenPrice;
    }

    // 현재 UNI 가격 반환
    function getUNIBalances() public view returns(uint) {
        (uint token1, uint token2) = getUNIBalance.getPoolBalances();
        uint currentTokenPrice = token1 / token2;
        return currentTokenPrice;
    }

    // insurPool (EOA) > 0x88cDBb31196Af16412F9a3D4196D645a830E5a4b
    // usdt > 0x617489EDf1b0E9546D34aA50f22194F582E17f81
    // BaseUri > https://teal-individual-peafowl-274.mypinata.cloud/ipfs/

    // uniswap pool DAI / wETH > 0x2F5136C8f0Bdf1DC797Cb52419D28143D6F72f93
    // uniswap pool DAI / UNI > 0x418b2be7F5ABE9a7104f503F8FCf25192A5e091f

    // 현재 배포, 프론트에서 사용중인 컨트랙트들 => 07.07.2023
    // erc20 - 0x617489EDf1b0E9546D34aA50f22194F582E17f81
    // gov - 0xC55a3701D0f6ec8064e46fc49013f0EaEE99554E
    // nft - 0x48780bcc6574134FaB9abd87101C7babD6D901fA
    // getbalance - 0x2F5136C8f0Bdf1DC797Cb52419D28143D6F72f93
}