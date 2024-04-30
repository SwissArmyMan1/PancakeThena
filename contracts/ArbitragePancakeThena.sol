// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import "./interfaces/IPancakeRouter01.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IRouterV2.sol";

contract ArbitragePancakeThena is Ownable, ChainlinkClient, AutomationCompatibleInterface {
    using Chainlink for Chainlink.Request;

    event CakeThena(bool value);
    event ThenaCake(bool value);
    event Try(bool value);
    bool public timer = false; //auto call arbitrage by timer
    bool public newBlock = false; //auto call arbitrage by new block
    bool public log = false;
    bool keeper = false;
    bool value = true;
    uint256 public gasPrice;
    uint256 public fee = ((10 * 10**18) / 100); //0.1 LINK, payment for chainlink in LINK
    uint256 slippage;
    uint256 lastUpdateTimeExchange;
    uint256 lastUpdateTimeGas;
    uint256 estimatedGasAmount;
    uint256 intervalExchange; // interval for Chainlink
    uint256 intervalGas; // interval for update gas price
    uint256 amountWBNB; // amount bnb for exchange
    uint256 lastBlockNumber;
    bytes32 public jobId; // for get uint256
    string public apiUrl; //api for update gas price via chainlink
    address[] public pancakePairs;
    address[] public thenaPairs;
    address public oracle; //address for get uint256 in BSC-mainnet (chainlink github)
    address constant tokenWBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant tokenLINK = 0x404460C6A5EdE2D891e8297795264fDe62ADBB75;
    address s_forwarderAddress;
    address trustedService;

    enum ArbitrageDirection {
        None,
        ThenaToPancake,
        PancakeToThena
    }
    struct ProfitInfo {
        uint256 profit;
        uint256 pairIndex;
    }
    
    IPancakeRouter01 internal pancakeRouter;
    IRouterV2 internal thenaRouterV2;

    constructor(uint256 _slippage,
                uint256 _intervalExchange,
                uint256 _intervalGas,
                uint256 _estimatedGasAmount,
                bytes32 _jobId,
                string memory _apiUrl,
                address _pancakeRouter,
                address _thenaRouterV2,
                address _oracle,
                address[] memory _pancakePairs,
                address[] memory _thenaPairs) Ownable(msg.sender) {
        slippage = _slippage;
        intervalExchange = _intervalExchange;
        intervalGas = _intervalGas;
        estimatedGasAmount = _estimatedGasAmount;
        jobId = _jobId;
        apiUrl = _apiUrl;
        pancakeRouter = IPancakeRouter01(_pancakeRouter);
        thenaRouterV2 = IRouterV2(_thenaRouterV2);
        oracle = _oracle;
        pancakePairs = _pancakePairs;
        thenaPairs   = _thenaPairs;

        lastUpdateTimeExchange = block.timestamp; // init last time
        lastUpdateTimeGas = block.timestamp;         
        lastBlockNumber = block.number;
        setChainlinkToken(tokenLINK);
    }

    modifier onlyTrustedAddresses() {
        require(msg.sender == trustedService || msg.sender == owner(), "Not a trusted address");
        _;
    }

    receive() external payable {}

    function getBalanceBNB() external view returns (uint256) {
        return address(this).balance;
    }

    function getBalanceWBNB() external view returns (uint256) {
        return IERC20(tokenWBNB).balanceOf(address(this));
    }

    function getBalanceERC20(address tokenContract) external view returns (uint256) {
        return IERC20(tokenContract).balanceOf(address(this));
    }

    function getBalanceAllPancakeERC20() external view returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](pancakePairs.length);
        
        for (uint i = 0; i < pancakePairs.length; i++) {
            address pairAddress = pancakePairs[i];
            address token0 = IPancakePair(pairAddress).token0();
            address token1 = IPancakePair(pairAddress).token1();

            address otherToken = token0 == tokenWBNB ? token1 : token0;
            balances[i] = IERC20(otherToken).balanceOf(pairAddress);
        }
        return balances;
    }

    function getBalanceAllThenaERC20() external view returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](thenaPairs.length);
        
        for (uint i = 0; i < thenaPairs.length; i++) {
            address pairAddress = thenaPairs[i];
            address token0 = IPair(pairAddress).token0();
            address token1 = IPair(pairAddress).token1();
            address otherToken = token0 == tokenWBNB ? token1 : token0;
            balances[i] = IERC20(otherToken).balanceOf(pairAddress);
        }
        return balances;
    }

    function getBalanceLINK() external view returns (uint256) {
        return IERC20(tokenLINK).balanceOf(address(this));
    }

    function getGasRequestSettings() external view returns(string memory, string memory, address, uint256) {
        return(apiUrl, string(abi.encodePacked(jobId)), oracle, fee);
    }

    function setGasRequestSettings(string memory _apiUrl, string memory _jobId, address _oracle, uint256 _fee) external onlyTrustedAddresses {
        apiUrl = _apiUrl;
        jobId = bytes32(bytes(_jobId));
        oracle = _oracle;
        fee = ((10 * _fee) / 100);
    }

    function setIntervalExchange(uint256 _intervalExchange) external onlyTrustedAddresses {
        intervalExchange = _intervalExchange;
    }

    function setIntervalGas(uint256 _intervalGas) external onlyTrustedAddresses {
        intervalGas = _intervalGas;
    }

    function setTypeOfEvent(bool setTimer, bool setBlock) external onlyTrustedAddresses {
        require(!(setTimer && setBlock), "setTimer and setBlock cannot both be true");
        timer = setTimer;
        newBlock = setBlock;
    }

    function setForwarderAddress(address forwarderAddress) external onlyTrustedAddresses { //setup of address of chainlink keepers
        s_forwarderAddress = forwarderAddress;
    }

    function setEstimatedGasAmount(uint256 _estimatedGasAmount) external onlyTrustedAddresses {
        estimatedGasAmount = _estimatedGasAmount;
    }

    function setGasPriceManual(uint256 _gasPrice) external onlyTrustedAddresses {
        gasPrice = _gasPrice * estimatedGasAmount;   //set in wei
    }

    function setSlippage(uint256 _slippage) external onlyTrustedAddresses {
        require(_slippage < 10000, "Slippage too high");  // Max 100% slippage
        slippage = _slippage;
    }

    function setTrustedService(address _trustedService) external onlyOwner {
        trustedService = _trustedService;
    }

    function setKeeper(bool _keeper) external onlyTrustedAddresses {
        keeper = _keeper;
    }

    function setLog(bool _log) external onlyTrustedAddresses {
        log = _log;
    }

    function addPairs(address _pancakePair, address _thenaPair) external onlyTrustedAddresses {
        pancakePairs.push(_pancakePair);
        thenaPairs.push(_thenaPair);
    }

    function removePairs(uint256 index) external onlyTrustedAddresses {
        require(index < pancakePairs.length, "Index out of bounds");
        require(index < thenaPairs.length, "Index out of bounds");

        pancakePairs[index] = pancakePairs[pancakePairs.length - 1];
        thenaPairs[index] = thenaPairs[thenaPairs.length - 1];
        
        pancakePairs.pop();
        thenaPairs.pop();
    }

    function checkUpByService() external onlyTrustedAddresses {
        require(keeper != true);
        if (timer) {
            _executeArbitrage();
        }
        if (newBlock) {
            require(block.number > lastBlockNumber);
            lastBlockNumber = block.number;
            _executeArbitrage();
        }
    }

    //function for repeat operation
    function checkUpkeep(bytes calldata /*checkData*/) external view override returns (bool upkeepNeeded, bytes memory /*performData*/) {
        bool upkeepForTimer = false;
        bool upkeepForNewBlock = false;
        if (timer && keeper) {
            upkeepForTimer = (block.timestamp - lastUpdateTimeExchange) > intervalExchange;
        }
        if (newBlock && keeper) {
            upkeepForNewBlock = block.number > lastBlockNumber;
        }
        upkeepNeeded = upkeepForTimer || upkeepForNewBlock;
        return (upkeepNeeded, new bytes(0));
        // performData is not used, so the return value can be comitted
    }

    function performUpkeep(bytes calldata /*performData*/) external override {
        require(
            msg.sender == s_forwarderAddress,
            "This address does not have permission to call performUpkeep"
        );
        if ((block.timestamp - lastUpdateTimeGas) > intervalGas) {
            lastUpdateTimeGas = block.timestamp;
            _requestGasPriceData();
        }
        lastBlockNumber = block.number;
        lastUpdateTimeExchange = block.timestamp;
        _executeArbitrage();
    }

    function requestGasPriceData() external onlyTrustedAddresses { //external request for update gas price
        _requestGasPriceData();
    }

    function _requestGasPriceData() internal returns (bytes32 requestId) {
        Chainlink.Request memory request = buildChainlinkRequest(jobId, address(this), this.fulfillUint.selector);
        request.add("get", apiUrl); // API to BscScan
        request.add("path", "result,ProposeGasPrice");  
        request.addInt("times", 1000000000);
        return sendChainlinkRequestTo(oracle, request, fee);
    }

    function fulfillUint(bytes32 _requestId, uint256 _gasPrice) public recordChainlinkFulfillment(_requestId) {
        gasPrice = _gasPrice * estimatedGasAmount; //convert from gwei to wei
    }
               
    function checkArbitrageOpportunity() internal view returns  (ArbitrageDirection direction, 
                                                                uint256 profitIndex,
                                                                uint256 reserveSlipFeePancakeBNB, 
                                                                uint256 reserveSlipFeePancakeOther, 
                                                                uint256 reserveSlipFeeThenaBNB, 
                                                                uint256 reserveSlipFeeThenaOther,
                                                                bool stable) {
        uint256 j = 0;  
        uint256 k = 0;
        uint256 pairsLength = pancakePairs.length;
        ProfitInfo[] memory profitsPancakeToThena = new ProfitInfo[](pairsLength);
        ProfitInfo[] memory profitsThenaToPancake = new ProfitInfo[](pairsLength);

        uint256 reservesThenaBNB;
        uint256 reservesThenaOther;
        uint256 reservesPancakeBNB;
        uint256 reservesPancakeOther;
        uint256 thenaFee;
        uint256 pancakeFee;

        for (uint256 i = 0; i < pairsLength; i++) {
            (reservesThenaBNB,
            reservesThenaOther,
            reservesPancakeBNB,
            reservesPancakeOther,
            thenaFee,
            pancakeFee,
            stable) = calculateComponents(i);

            if(reservesPancakeBNB*10000/reservesThenaBNB < reservesPancakeOther*10000/reservesThenaOther) {
                direction = ArbitrageDirection.PancakeToThena;
                profitsPancakeToThena[j] = ProfitInfo({
                    profit: reservesPancakeOther*10**12/reservesPancakeBNB*amountWBNB/reservesThenaOther*reservesThenaBNB/10**12,
                    pairIndex: i
                });
                j++;
            } else if(reservesPancakeBNB/reservesThenaBNB > reservesPancakeOther/reservesThenaOther) {
                direction = ArbitrageDirection.PancakeToThena;
                profitsThenaToPancake[k] = ProfitInfo({
                    profit: reservesThenaOther*10**12/reservesThenaBNB*amountWBNB/reservesPancakeOther*reservesPancakeBNB/10**12,
                    pairIndex: i
                });
                k++;
            } else {
                direction = ArbitrageDirection.None;
            }
        }

        heapSort(profitsPancakeToThena);
        heapSort(profitsThenaToPancake);
        if (profitsPancakeToThena[0].profit > profitsThenaToPancake[0].profit 
                && profitsPancakeToThena[0].profit* (10000 - pancakeFee) / 10000 * (10000 - slippage) / 10000 > gasPrice){
            direction = ArbitrageDirection.PancakeToThena;
            profitIndex = profitsPancakeToThena[0].pairIndex;
        } else if (profitsPancakeToThena[0].profit < profitsThenaToPancake[0].profit 
                && profitsThenaToPancake[0].profit* (10000 - thenaFee) / 10000 * (10000 - slippage) / 10000 > gasPrice){
            direction = ArbitrageDirection.ThenaToPancake;
            profitIndex = profitsThenaToPancake[0].pairIndex;
        } else {
            direction = ArbitrageDirection.None;
            revert("Invalid arbitrage direction");
        }

        (reservesThenaBNB,
        reservesThenaOther,
        reservesPancakeBNB,
        reservesPancakeOther,
        thenaFee,
        pancakeFee,
        stable) = calculateComponents(profitIndex);

        reserveSlipFeeThenaBNB = reservesThenaBNB* (10000 - thenaFee) / 10000 * (10000 - slippage) / 10000; //amountOutMinThena
        reserveSlipFeeThenaOther = reservesThenaOther* (10000 - thenaFee) / 10000 * (10000 - slippage) / 10000; //amountOutMinThena
        reserveSlipFeePancakeBNB = reservesPancakeBNB* (10000 - pancakeFee) / 10000 * (10000 -  slippage) / 10000; //amountOutMinPancake
        reserveSlipFeePancakeOther = reservesPancakeOther* (10000 - pancakeFee) / 10000 * (10000 - slippage) / 10000; //amountOutMinPancake
        return  (direction, profitIndex, reserveSlipFeePancakeBNB, reserveSlipFeePancakeOther, 
                reserveSlipFeeThenaBNB, reserveSlipFeeThenaOther, stable);
    }

    function calculateComponents(uint256 i) internal view returns(uint256 reservesThenaBNB,
                                                                uint256 reservesThenaOther,
                                                                uint256 reservesPancakeBNB,
                                                                uint256 reservesPancakeOther,
                                                                uint256 thenaFee,
                                                                uint256 pancakeFee,
                                                                bool stable) {
        (uint256 pancakeReserve0, uint256 pancakeReserve1,) = IPancakePair(pancakePairs[i]).getReserves();
        (uint256 thenaReserve0, uint256 thenaReserve1,) = IPair(thenaPairs[i]).getReserves();
        stable = IPair(thenaPairs[i]).isStable();
        if (stable == true){
            thenaFee = 1;
            pancakeFee = 1;
        }
        else{
            thenaFee = 20;
            pancakeFee = 25;
        }

        if (IPancakePair(pancakePairs[i]).token0() == tokenWBNB) { 
            reservesPancakeBNB = pancakeReserve0;
            reservesPancakeOther = pancakeReserve1;
        } else {
            reservesPancakeBNB = pancakeReserve1;  
            reservesPancakeOther = pancakeReserve0;     
        }

        if (IPair(thenaPairs[i]).token0() == tokenWBNB) {
            reservesThenaBNB = thenaReserve0;
            reservesThenaOther = thenaReserve1;
        } else {
            reservesThenaBNB = thenaReserve1;
            reservesThenaOther = thenaReserve0;
        }
    }

    function heapSort(ProfitInfo[] memory arr) internal pure {
        uint256 n = arr.length;

        // Heap building
        for (uint256 i = n / 2 - 1; i < n; i--) {
            heapify(arr, n, i);
        }

        // Sorting
        for (uint256 i = n - 1; i > 0; i--) {
            // Swap
            (arr[0], arr[i]) = (arr[i], arr[0]);

            // Rebuild heap
            heapify(arr, i, 0);
        }
    }

    function heapify(ProfitInfo[] memory arr, uint256 n, uint256 i) internal pure {
        uint256 largest = i;
        uint256 left = 2 * i + 1;
        uint256 right = 2 * i + 2;

        // Left child larger than root
        if (left < n && arr[left].profit > arr[largest].profit)
            largest = left;

        // Right child larger than largest so far
        if (right < n && arr[right].profit > arr[largest].profit)
            largest = right;

        // If largest is not root
        if (largest != i) {
            (arr[i], arr[largest]) = (arr[largest], arr[i]);

            // Rebuild heap
            heapify(arr, n, largest);
        }
    }

    function executeArbitrage() external onlyTrustedAddresses {
        _executeArbitrage();
    }

    function _executeArbitrage() internal {
        if (log) {
            emit Try(value);
        }
        amountWBNB = address(this).balance;
        (ArbitrageDirection direction,
        uint256 profitIndex,  
        uint256 reserveSlipFeePancakeBNB, 
        uint256 reserveSlipFeePancakeOther, 
        uint256 reserveSlipFeeThenaBNB, 
        uint256 reserveSlipFeeThenaOther,
        bool stable) = checkArbitrageOpportunity();

        if (direction == ArbitrageDirection.ThenaToPancake) {
            executeThenaToPancakeArbitrage(profitIndex, reserveSlipFeeThenaOther, reserveSlipFeePancakeBNB, stable);
        } else if (direction == ArbitrageDirection.PancakeToThena) {
            executePancakeToThenaArbitrage(profitIndex, reserveSlipFeePancakeOther, reserveSlipFeeThenaBNB, stable);
        } else {
            revert("Invalid arbitrage direction");
        }
    }

    function executeThenaToPancakeArbitrage(uint256 profitIndex, uint256 amountOutMinThena, uint256 amountOutMinPancake, bool stable) internal {
        address firstTokenOut;
        if (IPancakePair(pancakePairs[profitIndex]).token0() == tokenWBNB) {
            firstTokenOut = IPancakePair(pancakePairs[profitIndex]).token1();
        } else {
            firstTokenOut = IPancakePair(pancakePairs[profitIndex]).token0();
        }

        address[] memory pathPancake = new address[](2);
        pathPancake[0] = firstTokenOut;
        pathPancake[1] = tokenWBNB; // address Wrapped BNB (WBNB)

        IRouterV2.route[] memory routes = new IRouterV2.route[](1);
        routes[0] = IRouterV2.route({
            from: tokenWBNB,
            to: firstTokenOut,
            stable: stable
        });

        try thenaRouterV2.swapExactTokensForTokens(
            amountWBNB,
            amountOutMinThena,
            routes,
            address(this),
            block.timestamp + 1200
        ) returns (uint256[] memory thenaOutputArray) {
            uint256 thenaOutput = thenaOutputArray[thenaOutputArray.length - 1];
            IERC20(firstTokenOut).approve(address(pancakeRouter), thenaOutput);

            try pancakeRouter.swapExactTokensForTokens(
                thenaOutput,
                amountOutMinPancake,
                pathPancake,
                address(this),
                block.timestamp + 1200
            ) {
                if(log) {
                    emit ThenaCake(value);
                }
            } catch {
                revert("Failed to sell on PancakeSwap");
            }
        } catch {
            revert("Failed to buy on Thena");
        }
    }

    function executePancakeToThenaArbitrage(uint256 profitIndex, uint256 amountOutMinPancake, uint256 amountOutMinThena, bool stable) internal {
        address firstTokenOut;
        if (IPancakePair(pancakePairs[profitIndex]).token0() == tokenWBNB) {
            firstTokenOut = IPancakePair(pancakePairs[profitIndex]).token1();
        } else {
            firstTokenOut = IPancakePair(pancakePairs[profitIndex]).token0();
        }

        address[] memory pathPancake = new address[](2);
        pathPancake[0] = tokenWBNB; // address Wrapped BNB (WBNB)
        pathPancake[1] = firstTokenOut;

        IRouterV2.route[] memory routes = new IRouterV2.route[](1);
        routes[0] = IRouterV2.route({
            from: firstTokenOut,
            to: tokenWBNB,
            stable: stable
        });

        try pancakeRouter.swapExactTokensForTokens(
            amountWBNB,
            amountOutMinPancake,
            pathPancake,
            address(this),
            block.timestamp + 1200
        ) returns (uint256[] memory pancakeOutputArray) {
            uint256 pancakeOutput = pancakeOutputArray[pancakeOutputArray.length - 1];
            IERC20(firstTokenOut).approve(address(thenaRouterV2), pancakeOutput);
            
            try thenaRouterV2.swapExactTokensForTokens(
                pancakeOutput, 
                amountOutMinThena, 
                routes, 
                address(this), 
                block.timestamp + 1200
            ) {
                if(log) {
                    emit CakeThena(value);
                }
            } catch {
                revert("Failed to sell on Thena");
            }
        } catch {
            revert("Failed to buy on PancakeSwap");
        }
    }

    function withdrawBNB(address payable recipient, uint256 amount) external onlyOwner {
        uint256 withdrawAmount = (amount > address(this).balance) ? address(this).balance : amount;
        require(withdrawAmount > 0, "No BNB to withdraw");
        // Sending the determined amount of BNB to a specified address
        (bool sent, ) = recipient.call{value: withdrawAmount}("");
        require(sent, "Failed to send BNB");
    }

    function withdrawAllBNB(address payable recipient) external onlyOwner {
        require(address(this).balance > 0, "No BNB to withdraw");
        // Sending all BNB to a specified address
        (bool sent, ) = recipient.call{value: address(this).balance}("");
        require(sent, "Failed to send BNB");
    }

    function withdrawAllWBNB(address recipient) public onlyOwner {
        IERC20 wbnb = IERC20(tokenWBNB);
        uint256 balance = wbnb.balanceOf(address(this));
        require(balance > 0, "No ERC20 tokens to withdraw");

        bool sent = wbnb.transfer(recipient, balance);
        require(sent, "Failed to send ERC20 tokens");
    }

    function withdrawAllSetERC20(address tokenAddress, address recipient) external onlyOwner {
        // Sending all IERC20 token to a specified address
        IERC20 token = IERC20(tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "No ERC20 tokens to withdraw");

        bool sent = token.transfer(recipient, tokenBalance);
        require(sent, "Failed to send ERC20 tokens");
    }

    function withdrawAllSetAmountERC20(address tokenAddress, address recipient, uint256 amount) external onlyOwner {
        // Sending all IERC20 token to a specified address
        IERC20 token = IERC20(tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "No ERC20 tokens to withdraw");

        bool sent = token.transfer(recipient, amount);
        require(sent, "Failed to send ERC20 tokens");
    }

    function withdrawAllLINK(address recipient) external onlyOwner {
        IERC20 linkToken = IERC20(tokenLINK);
        uint256 balance = linkToken.balanceOf(address(this));
        require(balance > 0, "No LINK tokens to withdraw");
        
        bool sent = linkToken.transfer(recipient, balance);
        require(sent, "Failed to send ERC20 tokens");
    }

    function withdrawLINK(address recipient, uint256 amount) external onlyOwner {
        uint256 withdrawAmount = (amount > address(this).balance) ? address(this).balance : amount;
        require(withdrawAmount > 0, "No BNB to withdraw");
        IERC20 linkToken = IERC20(tokenLINK);

        bool sent = linkToken.transfer(recipient, withdrawAmount);
        require(sent, "Failed to send ERC20 tokens");
    }
}