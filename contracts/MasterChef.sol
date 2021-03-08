// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./BeeToken.sol";

// MasterChef is the master of BEE. He can make BEE and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once BEE is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
    }

    // Info of each user.
    struct LimitedPoolUserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. BEEs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that BEEs distribution occurs.
        uint256 accBeePerShare;   // Accumulated BEEs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // Info of each limited pool.
    struct LimitedPoolInfo {
        IBEP20 lpToken;                 // Address of LP token contract.
        uint256 allocPoint;             // How many allocation points assigned to this pool. BEEs to distribute per block.
        uint256 lastRewardBlock;        // Last block number that BEEs distribution occurs.
        uint256 accBeePerShare;         // Accumulated BEEs per share, times 1e12. See below.
        uint256 depositFeeBP;           // Deposit fee in basis points
        uint256 maxDepositAmount;       // Maximum deposit quota (0 means no limit)
        uint256 currentDepositAmount;   // Current total deposit amount in this pool
    }

    // The BEE TOKEN!
    BeeToken public bee;
    // Dev address.
    address public devaddr;
    // BEE tokens created per block.
    uint256 public beePerBlock;
    // BEE tokens created per block.
    uint256 public limitedPoolBeePerBlock;
    // Bonus muliplier for early BEE makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    LimitedPoolInfo[] public limitedPoolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => mapping(address => LimitedPoolUserInfo)) public limitedPoolUserInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public limitedPoolTotalAllocPoint = 0;
    // The block number when BEE mining starts.
    uint256 public startBlock;
    uint256 public limitedPoolStartBlock;
    bool isContractPaused = true;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 beePerBlock);
    event SetPause(address indexed user, bool pause);
    event SetBurnFee(address indexed user, uint256 burnFee);
    event SetAccountExcluded(address indexed sender, address indexed account, bool excluded);

    constructor(
        BeeToken _bee,
        address _devaddr,
        address _feeAddress,
        uint256 _normalPoolBeePerBlock,
        uint256 _normalPoolStartBlock,
        uint256 _limitedPoolBeePerBlock,
        uint256 _limitedPoolStartBlock
    ) public {
        bee = _bee;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        beePerBlock = _normalPoolBeePerBlock;
        startBlock = _normalPoolStartBlock;
        limitedPoolBeePerBlock = _limitedPoolBeePerBlock;
        limitedPoolStartBlock = _limitedPoolStartBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function limitedPoolLength() external view returns (uint256) {
        return limitedPoolInfo.length;
    }

    mapping(IBEP20 => bool) public normalPoolExistence;
    modifier nonDuplicatedNormalPool(IBEP20 _lpToken) {
        require(normalPoolExistence[_lpToken] == false, "nonDuplicated: normal pool already exists");
        _;
    }

    mapping(IBEP20 => bool) public limitedPoolExistence;
    modifier nonDuplicatedLimitedPool(IBEP20 _lpToken) {
        require(limitedPoolExistence[_lpToken] == false, "nonDuplicatedLimited: limited pool already exists");
        _;
    }

    // Pause or Unpause adding liquidity to MasterChef.
    // Everything else will still work only deposits will be paused.
    function setPause(bool _isContractPaused) external onlyOwner() {
        isContractPaused = _isContractPaused;
        emit SetPause(msg.sender, _isContractPaused);
    }

    // Check if contract is paused.
    function getIsPause() public view returns (bool) {
        return isContractPaused;
    }

    // Set transaction burn fee. Can not be higher than 40%
    function setBurnFee(uint256 _burnFee) public onlyOwner() {
        require(_burnFee < 4000, 'BEP20: burn fee cant exceed 40%');
        bee.setBurnFee(_burnFee);
        emit SetBurnFee(msg.sender, _burnFee);
    }

    // Exclude account from transaction fee and MasterChef pause.
    function setAccountExcluded(address _account, bool _excluded) external onlyOwner() {
        bee.setAccountExcluded(_account, _excluded);
        emit SetAccountExcluded(msg.sender, _account, _excluded);
    }

    // Check if account is excluded from transaction fee and MasterChef pause.
    function getIsExcluded(address _account) public view returns (bool) {
        return bee.getIsExcluded(_account);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: sender is not current dev");
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    // Change Fee Address.
    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: sender is not current fee address");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    // Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _normalPoolBeePerBlock) public onlyOwner {
        massUpdatePools();
        beePerBlock = _normalPoolBeePerBlock;
        emit UpdateEmissionRate(msg.sender, _normalPoolBeePerBlock);
    }

    // Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRateLimitedPool(uint256 _limitedPoolBeePerBlock) public onlyOwner {
        massUpdateLimitedPools();
        limitedPoolBeePerBlock = _limitedPoolBeePerBlock;
        emit UpdateEmissionRate(msg.sender, _limitedPoolBeePerBlock);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
     function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner nonDuplicatedNormalPool(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        normalPoolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accBeePerShare : 0,
            depositFeeBP : _depositFeeBP
        }));
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
     function addLimitedPool(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) public onlyOwner nonDuplicatedLimitedPool(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdateLimitedPools();
        }
        uint256 lastRewardBlock = block.number > limitedPoolStartBlock ? block.number : limitedPoolStartBlock;
        limitedPoolTotalAllocPoint = limitedPoolTotalAllocPoint.add(_allocPoint);
        limitedPoolExistence[_lpToken] = true;
        limitedPoolInfo.push(LimitedPoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accBeePerShare : 0,
            depositFeeBP : _depositFeeBP,
            maxDepositAmount: _maxDepositAmount,
            currentDepositAmount: 0
        }));
    }

    // Update the given pool's BEE allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Update the given pool's BEE allocation point and deposit fee. Can only be called by the owner.
    function setLimitedPool(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdateLimitedPools();
        }
        limitedPoolTotalAllocPoint = limitedPoolTotalAllocPoint.sub(limitedPoolInfo[_pid].allocPoint).add(_allocPoint);
        limitedPoolInfo[_pid].allocPoint = _allocPoint;
        limitedPoolInfo[_pid].depositFeeBP = _depositFeeBP;
        limitedPoolInfo[_pid].maxDepositAmount = _maxDepositAmount;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending BEEs on frontend.
    function pendingBee(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBeePerShare = pool.accBeePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 beeReward = multiplier.mul(beePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accBeePerShare = accBeePerShare.add(beeReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accBeePerShare).div(1e12).sub(user.rewardDebt);
    }

    // View function to see pending BEEs on frontend.
    function pendingBeeLimitedPool(uint256 _pid, address _user) external view returns (uint256) {
        LimitedPoolInfo storage pool = limitedPoolInfo[_pid];
        LimitedPoolUserInfo storage user = limitedPoolUserInfo[_pid][_user];
        uint256 accBeePerShare = pool.accBeePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 beeReward = multiplier.mul(limitedPoolBeePerBlock).mul(pool.allocPoint).div(limitedPoolTotalAllocPoint);
            accBeePerShare = accBeePerShare.add(beeReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accBeePerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdateLimitedPools() public {
        uint256 length = limitedPoolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updateLimitedPool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 beeReward = multiplier.mul(beePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        bee.mint(devaddr, beeReward.div(10));
        bee.mint(address(this), beeReward);
        pool.accBeePerShare = pool.accBeePerShare.add(beeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Update reward variables of the given pool to be up-to-date.
    function updateLimitedPool(uint256 _pid) public {
        LimitedPoolInfo storage pool = limitedPoolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 beeReward = multiplier.mul(limitedPoolBeePerBlock).mul(pool.allocPoint).div(limitedPoolTotalAllocPoint);
        bee.mint(devaddr, beeReward.div(10));
        bee.mint(address(this), beeReward);
        pool.accBeePerShare = pool.accBeePerShare.add(beeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for BEE allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        if (isContractPaused) {
            require(getIsExcluded(msg.sender), "deposit: contract is paused and account is not excluded");
        }
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accBeePerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeBeeTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0){
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
            } else{
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accBeePerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Deposit LP tokens to MasterChef for BEE allocation.
    function depositLimitedPool(uint256 _pid, uint256 _amount) public nonReentrant {
        if (isContractPaused) {
            require(getIsExcluded(msg.sender), "deposit: contract is paused and account is not excluded");
        }
        LimitedPoolInfo storage limitedPool = limitedPoolInfo[_pid];
        LimitedPoolUserInfo storage user = limitedPoolUserInfo[_pid][msg.sender];
        updateLimitedPool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(limitedPool.accBeePerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeBeeTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            uint256 depositFee = _amount.mul(limitedPool.depositFeeBP).div(10000);
            uint256 depositAmount = _amount.sub(depositFee);

            //Ensure adequate deposit quota if there is a max cap
            if(limitedPool.maxDepositAmount > 0){
                uint256 remainingQuota = limitedPool.maxDepositAmount.sub(limitedPool.currentDepositAmount);
                require(remainingQuota >= depositAmount, "deposit: reached maximum limit");
            }

            limitedPool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (depositFee > 0) {
                limitedPool.lpToken.safeTransfer(feeAddress, depositFee);
            }
            user.amount = user.amount.add(depositAmount);
            limitedPool.currentDepositAmount = limitedPool.currentDepositAmount.add(depositAmount);
        }
        user.rewardDebt = user.amount.mul(limitedPool.accBeePerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accBeePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeBeeTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accBeePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdrawLimitedPool(uint256 _pid, uint256 _amount) public nonReentrant {
        LimitedPoolInfo storage limitedPool = limitedPoolInfo[_pid];
        LimitedPoolUserInfo storage user = limitedPoolUserInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updateLimitedPool(_pid);
        uint256 pending = user.amount.mul(limitedPool.accBeePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeBeeTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            limitedPool.currentDepositAmount = limitedPool.currentDepositAmount.sub(_amount);
            limitedPool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(limitedPool.accBeePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdrawLimited(uint256 _pid) public nonReentrant {
        LimitedPoolInfo storage limitedPool = limitedPoolInfo[_pid];
        LimitedPoolUserInfo storage user = limitedPoolUserInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        limitedPool.currentDepositAmount = limitedPool.currentDepositAmount.sub(amount);
        limitedPool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe bee transfer function, just in case if rounding error causes pool to not have enough BEEs.
    function safeBeeTransfer(address _to, uint256 _amount) internal {
        uint256 beeBal = bee.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > beeBal) {
            transferSuccess = bee.transfer(_to, beeBal);
        } else {
            transferSuccess = bee.transfer(_to, _amount);
        }
        require(transferSuccess, "safeBeeTransfer: transfer failed");
    }
}
