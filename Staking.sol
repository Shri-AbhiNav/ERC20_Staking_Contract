// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TokenStaking1 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable rootAddress;
    address public owner;
    IERC20 public immutable token;
    uint256 private totalStaked;
    uint256 private userCount;

    enum TransactionType { Stake, RewardDistribution, LevelUpReward, ReferralReward }

    struct Transaction {
        TransactionType txType;
        address user;
        uint256 amount;
        uint256 timestamp;
    }

    mapping(address => uint256) public stakedAmounts;
    mapping(address => bool) private registeredUsers;
    mapping(address => string) public userNames;
    mapping(address => address) public referrerOf;
    mapping(address => address[]) private referrals;
    mapping(address => Transaction[]) private userTransactions;
    mapping(address => uint256) public signUpTimestamps;
    mapping(address => uint256) public lastRewardTimestamps;

    event Staked(address indexed staker, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event UserRegistered(address indexed user, address indexed referrer, string userName, uint256 stakeAmount);
    event StakingRewardDistributed(address indexed user, uint256 rewardAmount);
    event LevelUpRewardDistributed(address indexed user, address indexed referrer, uint256 rewardAmount);
    event ReferralRewardDistributed(address indexed user, address indexed referrer, uint256 rewardAmount);

    constructor(address _tokenAddress, address _rootAddress) {
        owner = msg.sender;
        rootAddress = _rootAddress;
        token = IERC20(_tokenAddress);
        registeredUsers[rootAddress] = true;
        userCount = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    modifier onlyRegistered() {
        require(registeredUsers[msg.sender], "User is not registered");
        _;
    }

    function signUp(address referrer, string calldata userName, uint256 stakeAmount) external {
        address user = msg.sender;

        require(!registeredUsers[user], "User is already registered");
        require(stakeAmount > 0, "Stake amount must be greater than 0");
        require(referrer != user, "User cannot refer themselves");
        require(registeredUsers[referrer], "Referrer must be already registered");

        registeredUsers[user] = true;
        userNames[user] = userName;
        referrerOf[user] = referrer;
        referrals[referrer].push(user);
        userCount++;
        signUpTimestamps[user] = block.timestamp;
        lastRewardTimestamps[user] = block.timestamp;

        _stake(user, stakeAmount);
        _levelUpReward(user, stakeAmount);
        _referralReward(user, stakeAmount);

        emit UserRegistered(user, referrer, userName, stakeAmount);
    }

    function _stake(address user, uint256 amount) internal {
        require(amount > 0, "Amount must be greater than 0");
        token.safeTransferFrom(user, address(this), amount);
        stakedAmounts[user] += amount;
        totalStaked += amount;

        userTransactions[user].push(Transaction({
            txType: TransactionType.Stake,
            user: user,
            amount: amount,
            timestamp: block.timestamp
        }));

        emit Staked(user, amount);
    }

    function stake(uint256 amount) external onlyRegistered nonReentrant {
        _stake(msg.sender, amount);
    }

    function transfer(address to, uint256 amount) external onlyOwner nonReentrant {
        _internalTransfer(to, amount);
    }

    function _internalTransfer(address to, uint256 amount) internal {
        require(amount > 0, "Amount must be greater than 0");
        require(totalStaked >= amount, "Insufficient total staked amount");
        token.safeTransfer(to, amount);
        totalStaked -= amount;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function balanceOfContract() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function userExists(address user) external view returns (bool) {
        return registeredUsers[user];
    }

    function getReferralTree(address user) external view returns (address[][] memory) {
        address[][] memory result = new address[][](userCount);
        //uint256 head = 0;
        //uint256 tail = 0;
        uint256 level = 0;

        address[] memory currentLevel = new address[](1);
        currentLevel[0] = user;
        result[level] = currentLevel;

        while (true) {
            uint256 count = 0;
            for (uint256 i = 0; i < result[level].length; i++) {
                count += referrals[result[level][i]].length;
            }

            if (count == 0) break;

            address[] memory nextLevel = new address[](count);
            uint256 index = 0;

            for (uint256 i = 0; i < result[level].length; i++) {
                address[] memory currentUserReferrals = referrals[result[level][i]];
                for (uint256 j = 0; j < currentUserReferrals.length; j++) {
                    nextLevel[index] = currentUserReferrals[j];
                    index++;
                }
            }

            level++;
            result[level] = nextLevel;
        }

        address[][] memory trimmedResult = new address[][](level + 1);
        for (uint256 i = 0; i <= level; i++) {
            trimmedResult[i] = result[i];
        }

        return trimmedResult;
    }

    function Staking_Rewards() external onlyOwner nonReentrant {
        address[] memory allUsers = referrals[rootAddress];
        uint256 currentTime = block.timestamp;
        uint256 contractBalance = token.balanceOf(address(this));

        for (uint256 i = 0; i < allUsers.length; i++) {
            address user = allUsers[i];

            if (
                currentTime >= signUpTimestamps[user] + 24 hours &&
                currentTime >= lastRewardTimestamps[user] + 24 hours
            ) {
                uint256 stakedAmount = stakedAmounts[user];

                if (stakedAmount > 0) {
                    uint256 reward = stakedAmount / 20;

                    if (contractBalance >= reward) {
                        token.safeTransfer(user, reward);
                        contractBalance -= reward;

                        userTransactions[user].push(Transaction({
                            txType: TransactionType.RewardDistribution,
                            user: user,
                            amount: reward,
                            timestamp: currentTime
                        }));

                        lastRewardTimestamps[user] = currentTime;

                        emit StakingRewardDistributed(user, reward);
                    }
                }
            }
        }
    }

    function _levelUpReward(address user, uint256 stakeAmount) internal {
        address currentReferrer = referrerOf[user];
        uint256[] memory rewards = new uint256[](5);
        address[] memory referrers = new address[](5);
        uint256 rewardPercent = 5;
        uint256 totalReward = 0;
        uint256 index = 0;

        while (currentReferrer != address(0) && rewardPercent > 0 && index < 5) {
            if (currentReferrer != rootAddress && currentReferrer != referrerOf[user]) {
                uint256 reward = (stakeAmount * rewardPercent) / 100;
                rewards[index] = reward;
                referrers[index] = currentReferrer;
                totalReward += reward;
                index++;
            }
            currentReferrer = referrerOf[currentReferrer];
            rewardPercent--;
        }

        require(token.balanceOf(address(this)) >= totalReward, "Insufficient balance in contract to distribute Level_UP Rewards");

        for (uint256 i = 0; i < index; i++) {
            token.safeTransfer(referrers[i], rewards[i]);

            userTransactions[referrers[i]].push(Transaction({
                txType: TransactionType.LevelUpReward,
                user: referrers[i],
                amount: rewards[i],
                timestamp: block.timestamp
            }));

            emit LevelUpRewardDistributed(user, referrers[i], rewards[i]);
        }
    }

    function _referralReward(address user, uint256 stakeAmount) internal {
        address referrer = referrerOf[user];

        if (referrer != rootAddress) {
            uint256 referralReward = (stakeAmount * 5) / 100;
            require(token.balanceOf(address(this)) >= referralReward, "Insufficient balance in contract to distribute Referral Rewards");

            token.safeTransfer(referrer, referralReward);

            userTransactions[referrer].push(Transaction({
                txType: TransactionType.ReferralReward,
                user: referrer,
                amount: referralReward,
                timestamp: block.timestamp
            }));

            emit ReferralRewardDistributed(referrer, user, referralReward);
        }
    }

    function getTransactions(address user) external view returns (Transaction[] memory) {
        return userTransactions[user];
    }

    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(token.balanceOf(address(this)) >= amount, "Insufficient balance in contract");

        token.safeTransfer(owner, amount);
    }

    struct TransferInfo {
        address recipient;
        uint256 amount;
    }

    function batchTransfer(TransferInfo[][] calldata transfers) external onlyOwner nonReentrant {
        for (uint256 i = 0; i < transfers.length; i++) {
            uint256 totalAmount = 0;

            for (uint256 j = 0; j < transfers[i].length; j++) {
                require(transfers[i][j].amount > 0, "Amount must be greater than 0");
                totalAmount += transfers[i][j].amount;
            }

            require(token.balanceOf(address(this)) >= totalAmount, "Insufficient balance in contract");
    
            for (uint256 j = 0; j < transfers[i].length; j++) {
                token.safeTransfer(transfers[i][j].recipient, transfers[i][j].amount);
                totalStaked -= transfers[i][j].amount;
            }
        }
    }

/*
    [
            ["0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2", 100],
            ["0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db", 222],
            ["0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB", 301],
            ["0x617F2E2fD72FD9D5503197092aC168c91465E7f2", 125]
    ]
*/ 


    fallback() external {
        revert("Contract does not accept Ether");
    }

    receive() external payable {
        revert("Contract does not accept Ether");
    }
}
