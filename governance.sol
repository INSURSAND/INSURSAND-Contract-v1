// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.18;

/*
    거버넌스 투표
    1. 유저는 하나의 투표권을 사용하여 안건을 제안할 수 있다.
    2. 유저는 제안된 안건 하나당 최대 3번을 투표할 수 있다.
    3. 모든 안건은 2주가 지나면 종료된다. 프로젝트 초기에는 찬성이 반대보다 많다면 가결.
        유저가 많아지면, 모든 유저수의 20% 만큼의 투표수를 받고 찬성이 반대보다 많아야 가결.
        이 외에는 모두 부결처리. 유저가 많아지면, admin 유저가 changeRule 함수를 통해서 룰을 바꿀 수 있다..
*/

contract governance {
    struct proposal {
        uint num; // 자동 카운팅
        uint time; // 자동 카운팅 ==> 2주가 지나면 더이상 투표가 불가능. 2주가 지난다면 close 된 것으로 간주.(frontend 에서 처리..)
        address maker; // msg.sender
        string subject;
        string Abstract;
        string method;
        string conclusion;
        uint accept;
        uint deny;
    }

    struct myStatus { 
        uint8 count;
        uint8 accept;
    } // 특정 유저의 정보 ( deny 투표수 = count - accept )
    
    proposal[] public proposals;

    mapping(address => mapping(uint => myStatus)) checkMyStatus; // 내 투표 확인하기
    mapping(address => uint) votePower; // 투표권 갯수
    
    address mintNFTContract;
    address admin;
    uint public P_number; // 제안된 안건 수.

    constructor(address _admin) {
        admin = _admin; 
    } // 관리자 지갑 주소 설정

    modifier checkVotePower{ 
        require(votePower[msg.sender] >= 1,"At least one voting power is required.");
        _;
    } // 유저가 갖고 있는 투표 수 확인

    function setMintNFTContract(address _addr) public {
        require(msg.sender == admin);
        mintNFTContract = _addr;
    } // mintNFT 컨트랙트 주소 설정

    function openProposal(string memory _subject, string memory _abstract, string memory _method, string memory _conclusion) public checkVotePower {
        votePower[msg.sender] -= 1;
        proposals.push( proposal ( ++P_number, block.timestamp, msg.sender,_subject, 
        _abstract, _method, _conclusion, 0, 0 ));
    } // 안건 제안. 투표권을 1개 소모하고, 2주가 지나면 자동으로 종료 됨.

    function openVotesAccept(uint P_numbers) public checkVotePower {
        require(checkMyStatus[msg.sender][P_numbers].count < 4,"Not allowed to vote on this proposal more than three times");
        require(proposals[P_numbers].time + 2 weeks > block.timestamp,"This proposal is already closed.");
        votePower[msg.sender] -= 1;
        proposals[P_numbers].accept++;
        checkMyStatus[msg.sender][P_numbers].count++;
        checkMyStatus[msg.sender][P_numbers].accept++;
    } // n번 안건 찬성 버튼을 누르면 작동

    function openVotesDeny(uint P_numbers) public checkVotePower {
        require(checkMyStatus[msg.sender][P_numbers].count < 4,"Not allowed to vote on this proposal more than three times");
        require(proposals[P_numbers].time + 2 weeks > block.timestamp,"This proposal is already closed.");
        votePower[msg.sender] -= 1;
        proposals[P_numbers].deny++;
        checkMyStatus[msg.sender][P_numbers].count++;
    } // n번 안건 반대 버튼을 누르면 작동

    function increaseVotePower(uint _number, address _address) external {
        require(mintNFTContract == msg.sender); // 민팅 컨트랙트에서만 호출 가능
        votePower[_address] += _number;
    } // NFT 구매 시, 투표권 증가시키는 함수. 다른 컨트랙트에서 사용됨.

    function userVoteCheck(uint P_numbers) public view returns(myStatus memory){
        return checkMyStatus[msg.sender][P_numbers]; 
    } // n번 안건에 투표 했는지 확인.

    function getVotePower(address msgsender) public view returns(uint){
        return votePower[msgsender]; 
    } // 유저의 투표권 갯수 값 불러오기

    function getP_number() public view returns(uint){
        return P_number; 
    } // 현재 제안된 안건의 갯수 값 불러오기

    function getMyStatus(uint P_numbers) public view returns(uint){
        return checkMyStatus[msg.sender][P_numbers].count; 
    } // 유저가 n번째 안건에 몇번 투표했는지 값 불러오기

    function getProposal(uint P_numbers) public view returns(proposal memory){
        return proposals[P_numbers]; 
    } // 안건번호로 카운팅.

    function Test_increasedVotePower() public {
        votePower[msg.sender] += 3;
    } // 테스트를 위해 만든 버튼!!!!!
}