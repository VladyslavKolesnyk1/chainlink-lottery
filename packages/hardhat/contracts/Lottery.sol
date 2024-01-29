// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

contract Lottery is Ownable, VRFConsumerBaseV2, AutomationCompatibleInterface {
    struct SingleLottery {
        bool claimed;
        bool winnerPicked;
        uint256 startTime;
        uint256 endTime;
        uint256 winningTicket;
        uint256 totalTickets;
    }

    bool public isActive;
    uint256 public currentLotteryId;
    address public forwarderAddress;
    mapping(uint256 requestId => uint256 lotteryId) public lotteryRequests;
    mapping(uint256 lotteryId => SingleLottery) public lotteries;
    mapping(uint256 lotteryId => mapping(address player => uint256 startingTicket)) public playerStartingTickets;
    mapping(uint256 lotteryId => mapping(address player => uint256 amount)) public playerTicketAmounts;

    bytes32 private immutable keyHash;
    uint16 private immutable requestConfirmations;
    uint64 private immutable subscriptionId;
    VRFCoordinatorV2Interface private immutable coordinator;

    uint32 private constant NUM_WORDS = 1;
    uint32 private constant CALLBACK_GAS_LIMIT = 200000;
    uint256 public constant TICKET_PRICE = 0.01 ether;

    constructor(address _vrfCoordinator, uint64 _subscriptionId, bytes32 _keyHash, uint16 _requestConfirmations, bool _isActive) Ownable(msg.sender) VRFConsumerBaseV2(_vrfCoordinator) {
        coordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        requestConfirmations = _requestConfirmations;

        isActive = _isActive;
    }

    function toggleIsActive() external onlyOwner {
        isActive = !isActive;
    }

    function setForwarderAddress(address _forwarderAddress) external onlyOwner {
        forwarderAddress = _forwarderAddress;
    }

    function createLottery() external onlyOwner {
        _createLottery();
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    )
    external
    view
    override
    returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        uint256 _currentLotteryId = currentLotteryId;
        SingleLottery memory _lottery = lotteries[_currentLotteryId];

        upkeepNeeded = !_lottery.winnerPicked && block.timestamp >= _lottery.endTime;
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        require(
            msg.sender == forwarderAddress,
            "This address does not have permission to call performUpkeep"
        );

        uint256 _currentLotteryId = currentLotteryId;
        SingleLottery memory _lottery = lotteries[_currentLotteryId];

        require(!_lottery.winnerPicked, "Winner has been picked");
        require(block.timestamp >= _lottery.endTime, "Lottery has not ended yet");

        uint256 requestId = coordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );

        lotteries[_currentLotteryId].winnerPicked = true;
        lotteryRequests[requestId] = _currentLotteryId;
    }

    function enterLottery(uint256 _amount) external payable {
        require(msg.value == _amount * TICKET_PRICE, "You need to send 0.01 ether per ticket");
        require(_amount > 0, "You need to buy at least one ticket");

        uint256 _currentLotteryId = currentLotteryId;
        SingleLottery memory _lottery = lotteries[_currentLotteryId];

        require(!_lottery.winnerPicked, "Winner has been picked");
        require(block.timestamp <= _lottery.endTime, "Lottery has already ended");
        require(block.timestamp >= _lottery.startTime, "Lottery has not started yet");
        require(playerTicketAmounts[_currentLotteryId][msg.sender] == 0, "You already have tickets in this lottery");

        uint256 _totalTickets = lotteries[_currentLotteryId].totalTickets;

        playerStartingTickets[_currentLotteryId][msg.sender] = _totalTickets;
        playerTicketAmounts[_currentLotteryId][msg.sender] = _amount;

        lotteries[_currentLotteryId].totalTickets += _amount;
    }

    function claimBatch(uint256[] memory _lotteryIds) external {
        for (uint256 i; i < _lotteryIds.length;) {
            claimReward(_lotteryIds[i]);

            unchecked {
                ++i;
            }
        }
    }

    function claimReward(uint256 _lotteryId) public {
        SingleLottery memory _lottery = lotteries[_lotteryId];

        require(_lottery.winnerPicked, "Lottery has not ended yet");
        require(!_lottery.claimed, "Lottery has already been claimed");
        require(_checkIfWinner(_lotteryId), "You are not a winner");

        lotteries[_lotteryId].claimed = true;

        uint256 _winningAmount = _calculateWinningAmount(_lottery);

        (bool _success,) = payable(msg.sender).call{value: _winningAmount}("");
        require(_success, "Failed to send Ether");
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        uint256 _lotteryId = lotteryRequests[_requestId];

        if (lotteries[_lotteryId].totalTickets == 0) {
            _createLottery();
            return;
        }

        lotteries[_lotteryId].winningTicket = _randomWords[0] % lotteries[_lotteryId].totalTickets;

        uint256 _fee = _calculateProtocolFee(_lotteryId);

        (bool _success,) = payable(owner()).call{value: _fee}("");
        require(_success, "Failed to send Ether");

        _createLottery();
    }

    function _createLottery() private {
        uint256 _currentLotteryId = currentLotteryId;

        if (isActive && (lotteries[_currentLotteryId].winnerPicked || _currentLotteryId == 0)) {
            lotteries[_currentLotteryId + 1].startTime = block.timestamp;
            lotteries[_currentLotteryId + 1].endTime = _calculateNextFinishTime(block.timestamp);
            currentLotteryId++;
        }
    }

    function _checkIfWinner(uint256 _lotteryId) private view returns (bool) {
        uint256 _startingTicket = playerStartingTickets[_lotteryId][msg.sender];
        uint256 _amount = playerTicketAmounts[_lotteryId][msg.sender];
        uint256 _winningTicket = lotteries[_lotteryId].winningTicket;

        if (_winningTicket < _startingTicket + _amount && _winningTicket >= _startingTicket) {
            return true;
        }

        return false;
    }

    function _calculateProtocolFee(uint256 _lotteryId) private view returns (uint256) {
        SingleLottery memory _lottery = lotteries[_lotteryId];
        uint256 _totalWinningAmount = _calculateWinningAmount(_lottery);

        return _totalWinningAmount * 10 / 100;
    }

    function _calculateWinningAmount(SingleLottery memory _lottery) private pure returns (uint256) {
        return _lottery.totalTickets * TICKET_PRICE;
    }

    function _calculateNextFinishTime(uint256 _timestamp) private pure returns (uint256) {
        uint256 _startOfCurrentHour = (_timestamp / 3600) * 3600;

        return _startOfCurrentHour + 3600;
    }
}
