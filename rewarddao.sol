//SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

interface IPinkAntiBot {
  function setTokenOwner(address owner) external;

  function onPreTransferCheck(
    address from,
    address to,
    uint256 amount
  ) external;
}

contract RewardDAO is ERC20, ERC20Burnable, ERC20Snapshot, Ownable {

    IPinkAntiBot public pinkAntiBot;
    bool public antiBotEnabled;

    using Address for address;
    using SafeERC20 for IERC20;

    /* SETTINGS */
    uint256 private _totalSupply;
    uint256 private _tTotal = 1000000000000000 * 10 ** 18;

    /* SWAP */
    IUniswapV2Router02 private uniswapV2Router;
    address private uniswapV2Pair;

    /* WALLETS */
    address payable public rewardAddress = payable(0x0FE2857f20Eb9F6C83B39B0fc7Da6E1F7adA58D2); // Reward Address
    address payable public marketingAddress = payable(0x65dCc51761b4d2d51c3fF8BBAc6Ec80b3086B60E); // Marketing Address
    address payable public nfttokenAddress = payable(0xf2A50a20233B7cbeF985a1645A14D317C1679540); // NFT Token Address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD; // Burn Address

    /* STATIC */
    uint8 private _decimals = 18;
    uint8 public constant BURN_AT_MINT = 37; // Burn Percent

    /* CLAIM */
    mapping (uint256 => address) public rounds;
    mapping (uint256 => mapping (address => uint256)) private _claims;
    address public claimedToken = address(0x0);
    uint256 public amountToDistribute = 0;
    event ClaimRewardToken(
        uint256 amount,
        address token,
        address recipient,
        uint256 round
    );

    /* FEES */
    uint256 public _rewardFee = 7;
    uint256 public _marketingFee = 3;
    uint256 public _nftFee = 2;
    uint256 public _burnFee = 1;

    /* LIMITS */
    uint256 public _maxTxAmount = 0;
    uint256 private buyRewardTokenLimit = 0;
    uint256 private minTokensBeforeSwap = 20000 * 10 ** 18; 
    uint256 private minTokensAllowClaim = 20000 * 10 ** 18;
    uint256 private _pointMultiplier = 10 ** 30;
    

    /* LISTS */
    mapping(address => uint256) public _balances;
    mapping(address => bool) public _isExcludedFromFee;

    /* PROCESSING */
    bool private inSwapAndLiquify;
    bool public swapAndLiquifyEnabled = false;
    bool public _transfersWithoutFee = false;

    /* EVENTS */
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapTokensForETH(
        uint256 amountIn,
        address[] path
    );

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }    

    constructor(address pinkAntiBot_) ERC20("RewardDAO", "RDAO") {

        // Create an instance of the PinkAntiBot variable from the provided address
        pinkAntiBot = IPinkAntiBot(pinkAntiBot_);
        // Register the deployer to be the token owner with PinkAntiBot. You can
        // later change the token owner in the PinkAntiBot contract
        pinkAntiBot.setTokenOwner(msg.sender);
        antiBotEnabled = true;

        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;
        _mint(msg.sender, _tTotal);
        _maxTxAmount = 30000000 * 10 ** 18;

        claimedToken = address(0);
        amountToDistribute = 0;

        uint256 _burnAmount = _tTotal * BURN_AT_MINT / 100;
        _balances[BURN_ADDRESS] = _burnAmount;
        _balances[msg.sender] = _tTotal - _burnAmount;
        emit Transfer(msg.sender, address(BURN_ADDRESS), _burnAmount);

        // TEST NET BSC ChainID 97 [ 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3 ]
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());
        uniswapV2Router = _uniswapV2Router;
    }

    function setEnableAntiBot(bool _enable) external onlyOwner {
        antiBotEnabled = _enable;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20) {
        
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        if (antiBotEnabled) { 
            pinkAntiBot.onPreTransferCheck(from, to, amount); 
        }

        _beforeTokenTransfer(from, to, amount);

        bool takeFee = true;        
        if(_isExcludedFromFee[from] || _isExcludedFromFee[to]){ takeFee = false; }

        if (_transfersWithoutFee && !(
            (to == uniswapV2Pair) || (from == uniswapV2Pair)
        )) {
            takeFee = false;
        }

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }

        uint256 contractTokenBalance = balanceOf(address(this));
        bool overMinimumTokenBalance = contractTokenBalance >= minTokensBeforeSwap;        
        if (!inSwapAndLiquify && swapAndLiquifyEnabled && to == uniswapV2Pair) {
            if (overMinimumTokenBalance) {
                swapTokens(contractTokenBalance);
            }
        }

        if (takeFee) {
            (uint256 _rewardAmount, uint256 _marketingAmount, uint256 _nftAmount, uint256 _burnAmount, uint256 _transferAmount) = _calculateFees(amount);        
            _balances[to] += _transferAmount;
            emit Transfer(from, to, _transferAmount);
            if (_rewardAmount > 0) _balances[address(this)] += _rewardAmount;
            if (_marketingAmount > 0) _balances[marketingAddress] += _marketingAmount;
            if (_nftAmount > 0) _balances[nfttokenAddress] += _nftAmount;
            if (_burnAmount > 0) {
                _balances[BURN_ADDRESS] += _burnAmount;
            }
        } else {
            _balances[to] += amount;
            emit Transfer(from, to, amount);
        }

        _afterTokenTransfer(from, to, amount);
    }

    function balanceOf(address account) public view override(ERC20) returns (uint256) {
        return _balances[account];
    }

    function _calculateFees(
        uint256 amount
    ) public view returns (uint256, uint256, uint256, uint256, uint256) {
        uint256 _rewardAmount = amount * _rewardFee / 100;
        uint256 _marketingAmount = amount * _marketingFee / 100;
        uint256 _nftAmount = amount * _nftFee / 100;
        uint256 _burnAmount = amount * _burnFee / 100;
        uint256 _feesAmount = _rewardAmount + _marketingAmount + _nftAmount + _burnAmount;
        uint256 _transferAmount = amount - _feesAmount;
        return(_rewardAmount, _marketingAmount, _nftAmount, _burnAmount, _transferAmount);
    }

    function _calculateFeesTransferAmount(
        uint256 amount
    ) public view returns (uint256, uint256, uint256) {
        uint256 _shares = _rewardFee + _marketingFee + _nftFee;
        uint256 _rewardShareAmount = amount * _rewardFee / _shares; 
        uint256 _marketingShareAmount = amount * _marketingFee / _shares;
        uint256 _nftShareAmount = amount * _nftFee / _shares;
        return(_rewardShareAmount, _marketingShareAmount, _nftShareAmount);
    }

    /* CLAIM SYSTEM */
    function buyRewardToken(address _claimedToken) public onlyOwner {
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = _claimedToken;
        uint256 _currentBalance = address(this).balance;
        (,uint256 _percent) = getCirculatingSupply();
        uint256 _amount = _currentBalance * _percent / 100;
        if ((buyRewardTokenLimit > 0) && (_currentBalance >= buyRewardTokenLimit)) { 
            _amount = buyRewardTokenLimit;
        }
        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: _amount}(0, path, address(this), block.timestamp);
    }

    // Set Claim Round
    function setClaimRound(address _token) public onlyOwner returns (bool) {
        require(_token != address(0), "setClaimRound: Claim Round Token is the zero address");
        uint256 _currentRound = _getCurrentSnapshotId();
        require(_currentRound > 0, "ERC20Snapshot: id is 0");
        if (_currentRound > 1) {
            uint256 prevRound = _currentRound - 1;
            require(rounds[prevRound] == address(0), "setClaimRound: Previous Claim Round should be finished");
        }
        rounds[_currentRound] = _token;
        claimedToken = _token;
        IERC20 _claimedToken = IERC20(claimedToken);
        amountToDistribute = _claimedToken.balanceOf(address(this));
        return true;
    }

    // Finish Claim Round
    function finishClaimRound(bool _transferTokens) public onlyOwner returns (bool) {
        uint256 _currentRound = _getCurrentSnapshotId();
        require(_currentRound > 0, "ERC20Snapshot: id is 0");
        IERC20 _claimedToken = IERC20(claimedToken);
        uint256 _lastBalance = _claimedToken.balanceOf(address(this));
        if(_transferTokens) _claimedToken.safeTransfer(msg.sender, _lastBalance);
        claimedToken = address(0);
        amountToDistribute = 0;
        return true;
    }

    // Get Amounts of Claim
    function checkClaimRoundAmount(address _holder) public view returns (uint256 supply, uint256 holdatvote, uint256 toclaim, uint256 amounttodistribute) {
        uint256 _currentRound = _getCurrentSnapshotId();
        require(_currentRound > 0, "ERC20Snapshot: id is 0");
        uint256 _holdAtVote = balanceOfAt(_holder, _currentRound);
        //uint256 _baseTokenSupply = totalSupply();
        (,uint256 _circulatingTokenSupply) = getCirculatingSupply();
        uint256 _amountToDistribute = amountToDistribute;
        uint256 _percentToPay = _holdAtVote * _pointMultiplier  / _circulatingTokenSupply;
        uint256 _amountTopay = _amountToDistribute * _percentToPay / _pointMultiplier;
        return (_circulatingTokenSupply, _holdAtVote, _amountTopay, _amountToDistribute);
    }

    // Claim
    function claimCurrentRound() external returns (bool) {
        require(claimedToken != address(0), "Claim disabled");
        address _holder = _msgSender();
        uint256 _currentRound = _getCurrentSnapshotId();
        (,uint256 _holdAtVote, uint256 _amountTopay,) = checkClaimRoundAmount(_holder);
        IERC20 _claimedToken = IERC20(claimedToken);
        uint256 _currentBalance = balanceOf(_holder);
        require(
            _holdAtVote >= minTokensAllowClaim && 
            _currentBalance >= minTokensAllowClaim, 
            "Not Eligible to Claim"
        );
        require(_amountTopay > 0, "Nothing to Claim");
        require(_claims[_currentRound][_holder] == 0, "Already claimed");
        _claims[_currentRound][_holder] = _amountTopay;        
        _claimedToken.safeTransfer(_holder, _amountTopay);
        emit ClaimRewardToken(_amountTopay, claimedToken, _holder, _getCurrentSnapshotId());
        return true;
    }

    /* SWAP */
    function swapTokens(uint256 contractTokenBalance) public lockTheSwap {       
        swapTokensForEth(contractTokenBalance);
        _balances[address(this)] = 0;
        uint256 transferredBalance = address(this).balance;
        (, uint256 _transferToMarketing, uint256 _transferToNft) = _calculateFeesTransferAmount(transferredBalance);
        //if (_transferToReward > 0) transferToAddressETH(rewardAddress, _transferToReward);
        if (_transferToMarketing > 0) transferToAddressETH(marketingAddress, _transferToMarketing);
        if (_transferToNft > 0) transferToAddressETH(nfttokenAddress, _transferToNft);        
    }

    function swapTokensForEth(uint256 tokenAmount) public {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);
        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this), // The contract
            block.timestamp
        );
        
        emit SwapTokensForETH(tokenAmount, path);
    }

    function swapClaimedTokenForEth(address tokenAddress, uint256 tokenAmount) public {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = tokenAddress;
        path[1] = uniswapV2Router.WETH();
        if (tokenAmount == 0) tokenAmount = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).approve(address(uniswapV2Router), tokenAmount);
        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this), // The contract
            block.timestamp
        );
        
        emit SwapTokensForETH(tokenAmount, path);
    }

    function transferToAddressETH(address payable recipient, uint256 amount) public {
        recipient.transfer(amount);
    }

    /* OPEN ZEPPLIN */
    
    function snapshot() public onlyOwner {
        _snapshot();
    }

    /* OVERRIDE */

    function renounceOwnership() public virtual onlyOwner override {
        revert("disabled");
    }

    function transferOwnership(address newOwner) public virtual onlyOwner override {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        address _currentOwner = owner();
        _transferOwnership(newOwner);
        _isExcludedFromFee[_currentOwner] = false;
        _isExcludedFromFee[newOwner] = true;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Snapshot)
    {
        super._beforeTokenTransfer(from, to, amount);

        if(from != owner() && to != owner())
            if(_maxTxAmount > 0)
                require(amount <= _maxTxAmount, "Transfer amount exceeds the maxTxAmount.");
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function setMinTokensBeforeSwap(uint256 _minTokensBeforeSwap) public onlyOwner {
        require(_minTokensBeforeSwap > 0, 'Must be more than zero');
        minTokensBeforeSwap = _minTokensBeforeSwap * 10 ** _decimals;
    }

    function setMaxTxAmount(uint256 amount) public onlyOwner {
        require(amount > 0, 'Must be more than zero');
        _maxTxAmount = amount * 10 ** _decimals;
    }

    function setMinClaimAmount(uint256 amount) public onlyOwner {
        require(amount > 0, 'Must be more than zero');
        minTokensAllowClaim = amount * 10 ** _decimals;
    }    

    function withdrawTokensFromBalance(address _token) public onlyOwner {
        require(_token != address(0), "withdrawTokensFromBalance: Token is the zero address");
        require(_token != address(this), "withdrawTokensFromBalance: Token is Native Contract Token");        
        IERC20 withdrawToken = IERC20(_token);
        uint256 tokenBalance = withdrawToken.balanceOf(address(this));
        if(tokenBalance > 0) withdrawToken.safeTransfer(msg.sender, tokenBalance);
    }

    function isExcludedFromFee(address account) external view returns(bool) {
        return _isExcludedFromFee[account];
    }
    
    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function setTaxes(uint256 newrewardFee, uint256 newmarketingFee, uint256 newnftFee, uint256 newburnFee) public onlyOwner {
        require((newrewardFee + newmarketingFee + newnftFee + newburnFee) < 25, "Exceed Fee Limits of 25%");
        _rewardFee = newrewardFee;
        _marketingFee = newmarketingFee;
        _nftFee = newnftFee;
        _burnFee = newburnFee;
    }

    function setRewardWallets(address _rewardAddress, address _marketingAddress, address _nfttokenAddress) public onlyOwner {
        require(_rewardAddress != address(0), "setRewardWallets: rewardAddress is the zero address");
        require(_marketingAddress != address(0), "setRewardWallets: marketingAddress is the zero address");
        require(_nfttokenAddress != address(0), "setRewardWallets: nfttokenAddress is the zero address");
        rewardAddress = payable(_rewardAddress);
        marketingAddress = payable(_marketingAddress);
        nfttokenAddress = payable(_nfttokenAddress);
    }

    function setMultiplier(uint256 pointMultiplier) public onlyOwner {
        _pointMultiplier = pointMultiplier;
    }

    function setExcludeCleanTransfersFromFee(bool _value) public onlyOwner {
        _transfersWithoutFee = _value;
    }

    // Helpers

    function getCirculatingSupply() public view returns(uint256 circulatingAmount, uint256 percent) {
        uint256 _circulatingAmount = _tTotal - _balances[BURN_ADDRESS];
        return(_circulatingAmount, _circulatingAmount * 100 / _tTotal);
    }

    //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {}
}