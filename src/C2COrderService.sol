// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AccessManagementTemplate} from "./AccessManagementTemplate.sol";

contract C2COrderService is AccessManagementTemplate, ReentrancyGuard {
    /* =======================================================
                        Type Declarations
    ======================================================= */

    using SafeERC20 for IERC20Metadata;
    using Math for uint256;

    enum OrderState {
        opening, // 正在市场挂单状态中的订单
        complete, // 挂单完成，所有nete都售出的订单
        cancel // 创建者取消挂单
    }

    struct MakerOrderDetail {
        address creator;
        bool isMarketMaker; // 创建order时是否是市商
        uint8 enableFlag; // 1 代表有效
        OrderState status; // 挂单状态
        uint256 id; // 位于 markerOrderList 中的索引，自创建后便不在改变
        uint256 statusPosIndex; // 位于 userTo($OrderState)MakerOrders 中的索引
        uint256 qtyForSale; // 售卖数量
        uint256 remainQtyForSale; // 剩余售卖数量
        uint256 usdtPricePerUnit; // 售卖单价
        uint256 createTimestamp; // 创建时间
        uint256 blockNumber; // 区块数
        uint256 baseFee; // 基础gas费
    }

    struct TakerOrderDetail {
        address creator;
        bool isMarketMaker; // 进行吃单的用户是否是市商身份
        uint8 enableFlag; // 1 代表有效
        uint256 id; // 位于 takerOrderList 中的索引，自创建后变不在改变
        uint256 neteQty; // 购买数量
        uint256 retainMakerNete; // 这个单吃完后，maker订单还剩多少nete
        uint256 createTimestamp; // 创建时间
        uint256 makerId; //  吃的挂单在markerOrderList中的索引
        uint256 price; // 吃单的价格     新增
        uint256 payUsdtAmount; // 吃单支付的usdt数量   新增
        uint256 blockNumber; // 区块数
        uint256 baseFee; // 基础gas费
    }

    /* =======================================================
                        State Variables
    ======================================================= */
    // uint256 public constant WAD = 18;

    // nete地址
    address public nete;

    // usdt地址
    address public usdt;

    // 矿机合约地址
    address public miningMachineAddr;

    // 应急保障金地址
    address public emergencyFundWallet;
    // 项目运营基金地址
    address public projectOperationWallet;
    // 项目方钱包地址
    address public projectPartyWallet;

    // 分母小数位
    uint256 public denominatorDeciamls;

    uint256 public generalPrice; // 普通用户售卖nete价格

    uint256 public marketMakerPrice; // 做市商售卖nete价格

    bool public makerEnable; // 挂单开关

    bool public takerEnable; // 吃单开关

    // 所有的挂单
    MakerOrderDetail[] public makerOrderList;

    // 所有的吃单
    TakerOrderDetail[] public takerOrderList;

    // 正在挂单的订单id
    uint256[] public openingMakerOrderList;

    // 已完成的挂单的id
    uint256[] public completeMakerOrderList;

    // 用户 创建的 Opening 状态的挂单
    mapping(address => uint256[]) public userToOpeningMakerOrders;

    // 用户 创建的 Complete 状态的挂单
    mapping(address => uint256[]) public userToCompleteMakerOrders;

    // 用户 创建的 Cancel 状态的挂单
    mapping(address => uint256[]) public userToCancelMakerOrders;

    // 用户吃单集合
    mapping(address => uint256[]) public userToTakerOrders;

    // 挂单的id 位于 openingMakerOrderList 中的索引位置， 负数，一般置为-1，表示该挂单已不存在于openingMakerOrderList
    mapping(uint256 => int256) public makerOrderIdInOpeningListIndex;

    // 是否为做市商的wallet
    mapping(address => bool) public marketMakerAllow;

    // 挂单黑名单
    mapping(address => bool) public makerBlackList;

    // 吃单黑名单
    mapping(address => bool) public takerBlackList;

    /* =======================================================
                        Events
    ======================================================= */
    event CreateMakerOrder(
        address indexed wallet,
        uint256 indexed amount,
        uint256 indexed orderId
    );

    event MakerOrderComplete(
        uint256 indexed orderId,
        uint256 indexed userToCompleteMakerOrdersIndex,
        uint256 indexed completeMakerOrderListIndex
    );

    event CreateTakerOrder(
        address indexed wallet,
        uint256 indexed amount,
        uint256 indexed orderId,
        uint256 payUsdtAmount
    );

    event CancelMakerOrder(
        address indexed wallet,
        uint256 indexed orderId,
        uint256 indexed userToCancelMakerOrdersIndex
    );

    /* =======================================================
                        Errors
    ======================================================= */
    error OrderBookSystem__CurrentMakerOrderIsNotOpening();
    error OrderBookSystem__InsufficientNeteAllowance();
    error OrderBookSystem__InsufficientNeteBalance();
    error OrderBookSystem__InsufficientUsdtAllowance();
    error OrderBookSystem__InsufficientUsdtBalance();

    error OrderBookSystem__CanNotTakeYourOwnMakerOrder();
    error OrderBookSystem__YouAreNotOwnerOfThisMakerOrder();
    error OrderBookSystem__MakerOrderHasNotSufficientRemaining();

    error OrderBookSystem__MakerIsNotOpen();
    error OrderBookSystem__TakerIsNotOpen();

    error OrderBookSystem__YouAreNotAllowedToMaker();
    error OrderBookSystem__YouAreNotAllowedToTaker();

    // error OrderBookSystem__InsufficientNeteInContract();

    /* =======================================================
                        Modifiers
    ======================================================= */

    // 挂单者不能吃自己的单
    modifier notMakerCreater(uint256 id) {
        if (msg.sender == makerOrderList[id].creator) {
            revert OrderBookSystem__CanNotTakeYourOwnMakerOrder();
        }
        _;
    }

    /* =======================================================
                            Functions
    ======================================================= */

    /* ------------------------------------------------------
                    Initializer/Constructor
    ------------------------------------------------------ */
    constructor(address _nete, address _usdt, address _miningMachine) {
        nete = _nete;
        miningMachineAddr = _miningMachine;
        // 将USDT统一为18位精度
        generalPrice = 5 * 10 ** 17; // 0.5 * 10 ** 18  usdt
        marketMakerPrice = 55 * 10 ** 16; // 0.55 * 10 ** 18 usdt

        denominatorDeciamls = 18;

        makerEnable = true;
        takerEnable = true;

        // BSC Test Net
        usdt = _usdt; // 0xacD944e910952c020eb129C50921f180c62c3291; usdx5 18位
        emergencyFundWallet = 0x48330A28d09161d9DEca84eaf841EDbE1a0c508d;
        projectOperationWallet = 0x48330A28d09161d9DEca84eaf841EDbE1a0c508d;
        projectPartyWallet = 0x48330A28d09161d9DEca84eaf841EDbE1a0c508d;
    }

    // 设置 购买矿机合约地址
    function setMiningMachineAddr(address _miningMachine) external onlyAdmin {
        miningMachineAddr = _miningMachine;
    }

    // 设置 nete地址
    function setNete(address newNeteAddr) external onlyAdmin {
        nete = newNeteAddr;
    }

    // 设置 usdt地址
    function setUsdt(address newUsdtAddr) external onlyAdmin {
        usdt = newUsdtAddr;
    }

    // 设置 应急保障金地址
    function setEmergencyFundWallet(address wallet) external onlyAdmin {
        emergencyFundWallet = wallet;
    }

    // 设置 项目运营基金地址
    function setProjectOperationWallet(address wallet) external onlyAdmin {
        projectOperationWallet = wallet;
    }

    // 设置 项目方钱包地址
    function setProjectPartyWallet(address wallet) external onlyAdmin {
        projectPartyWallet = wallet;
    }

    // 设置 支付总额 分母矫正
    function setDenominatorDeciamls(
        uint256 _denominatorDeciamls
    ) external onlyAdmin {
        denominatorDeciamls = _denominatorDeciamls;
    }

    // 设置 普通用户挂单nete的价格
    function setGeneralPrice(uint256 _generalPrice) external onlyManager {
        generalPrice = _generalPrice;
    }

    // 设置市商 挂单nete的价格
    function setMarketMakerPrice(
        uint256 _marketMakerPrice
    ) external onlyManager {
        marketMakerPrice = _marketMakerPrice;
    }

    // 设置做 市商 的 钱包地址
    function setMarketMaker(address wallet, bool auth) external onlyManager {
        marketMakerAllow[wallet] = auth;
    }

    // 设置是否允许挂单
    function setMakerEnable(bool enabled) external onlyManager {
        makerEnable = enabled;
    }

    // 设置是否允许吃单  manager
    function setTakerEnable(bool enabled) external onlyManager {
        takerEnable = enabled;
    }

    // 设置挂单黑名单  manager
    function setMakerBlackList(address wallet, bool auth) external onlyManager {
        makerBlackList[wallet] = auth;
    }

    // 设置吃单黑名单 manager
    function setTakerBlackList(address wallet, bool auth) external onlyManager {
        takerBlackList[wallet] = auth;
    }

    // 挂单
    function createNeteSellingMaker(uint256 neteAmount) external {
        require(neteAmount != 0, "Invalid Zero");

        if (!makerEnable) revert OrderBookSystem__MakerIsNotOpen();

        if (makerBlackList[msg.sender])
            revert OrderBookSystem__YouAreNotAllowedToMaker();

        // 确认用户的 NETE 授权和钱包余额
        if (
            IERC20Metadata(nete).allowance(msg.sender, address(this)) <
            neteAmount
        ) revert OrderBookSystem__InsufficientNeteAllowance();

        if (IERC20Metadata(nete).balanceOf(msg.sender) < neteAmount)
            revert OrderBookSystem__InsufficientNeteBalance();

        IERC20Metadata(nete).safeTransferFrom(
            msg.sender,
            address(this),
            neteAmount
        );

        // 查询用户是否是市商
        bool allow = marketMakerAllow[msg.sender];

        uint256 makerOrderListLength = getMakerOrderListLen();

        MakerOrderDetail memory newMakerOrderDetail = MakerOrderDetail({
            creator: msg.sender,
            enableFlag: 1,
            id: makerOrderListLength,
            statusPosIndex: 0,
            qtyForSale: neteAmount,
            remainQtyForSale: neteAmount,
            usdtPricePerUnit: allow ? marketMakerPrice : generalPrice,
            createTimestamp: block.timestamp,
            isMarketMaker: allow,
            status: OrderState.opening,
            blockNumber: block.number,
            baseFee: block.basefee
        });

        uint256 userToOpeningMakerOrdersLen = userToOpeningMakerOrders[
            msg.sender
        ].length;

        newMakerOrderDetail.statusPosIndex = userToOpeningMakerOrdersLen;

        userToOpeningMakerOrders[msg.sender].push(newMakerOrderDetail.id);

        openingMakerOrderList.push(newMakerOrderDetail.id);

        makerOrderIdInOpeningListIndex[newMakerOrderDetail.id] = int256(
            openingMakerOrderList.length - 1
        );

        makerOrderList.push(newMakerOrderDetail);

        emit CreateMakerOrder(msg.sender, neteAmount, makerOrderListLength);
    }

    // 吃单
    function neteBuyingTaker(
        uint256 id,
        uint256 buyNeteQty
    ) external notMakerCreater(id) nonReentrant {
        if (!takerEnable) revert OrderBookSystem__TakerIsNotOpen();

        if (takerBlackList[msg.sender])
            revert OrderBookSystem__YouAreNotAllowedToTaker();
        // require(makerOrderList.length != 0, "No maker orders");
        // require(id <= getMakerOrderListLen() - 1, "Invalid id");
        require(buyNeteQty != 0, "Invalid Zero");

        // uint256 id = openingMakerOrderList[index];

        MakerOrderDetail storage makerOrder = makerOrderList[id];

        address makerOrderOwner = makerOrder.creator;

        if (makerOrder.status != OrderState.opening) {
            revert OrderBookSystem__CurrentMakerOrderIsNotOpening();
        }

        // 检查 挂单余额
        if (buyNeteQty > makerOrder.remainQtyForSale) {
            revert OrderBookSystem__MakerOrderHasNotSufficientRemaining();
        }

        // 需要的USDT数量
        uint256 needUsdtAmount = Math.mulDiv(
            makerOrder.usdtPricePerUnit,
            buyNeteQty,
            10 ** denominatorDeciamls
        );

        // 检查用户钱包的USDT授权 和 余额
        if (
            IERC20Metadata(usdt).allowance(msg.sender, address(this)) <
            needUsdtAmount
        ) revert OrderBookSystem__InsufficientUsdtAllowance();

        if (IERC20Metadata(usdt).balanceOf(msg.sender) < needUsdtAmount)
            revert OrderBookSystem__InsufficientUsdtBalance();

        // 这里能触发说明系统出了严重问题
        // uint256 neteInContract = IERC20Metadata(nete).balanceOf(address(this));

        // if (neteInContract < neteAmount)
        //     revert OrderBookSystem__InsufficientNeteInContract();

        makerOrder.remainQtyForSale -= buyNeteQty; // makerOrder 更新

        if (makerOrder.remainQtyForSale == 0) {
            makerOrder.status = OrderState.complete; // makerOrder 更新

            _modifyUserToOpeningMakerOrders(
                makerOrderOwner,
                makerOrder.statusPosIndex
            );

            // 2. 将 makerOrder.id push到 userToCompleteMakerOrders
            userToCompleteMakerOrders[makerOrderOwner].push(makerOrder.id);
            // 2.1 更新 statusId
            // makerOrder 更新
            makerOrder.statusPosIndex =
                userToCompleteMakerOrders[makerOrderOwner].length -
                1;

            // 修改 openingMakerOrderList
            _removeMakerOrderIdFromOpeningMakerOrderList(makerOrder.id);

            // 3. Complete状态订单 id 放到 completeMakerOrderList 里
            completeMakerOrderList.push(makerOrder.id);

            emit MakerOrderComplete(
                makerOrder.id,
                makerOrder.statusPosIndex,
                completeMakerOrderList.length - 1
            );
        }

        // 将 usdt转移到合约
        IERC20Metadata(usdt).safeTransferFrom(
            msg.sender,
            address(this),
            needUsdtAmount
        );

        uint256 takerOrderListLength = getTakerOrderListLen();

        bool takerIsMarketMaker = marketMakerAllow[msg.sender];

        TakerOrderDetail memory newTakerOrderDetail = TakerOrderDetail({
            id: takerOrderListLength,
            isMarketMaker: takerIsMarketMaker,
            enableFlag: 1,
            creator: msg.sender,
            neteQty: buyNeteQty,
            retainMakerNete: makerOrder.remainQtyForSale,
            createTimestamp: block.timestamp,
            makerId: makerOrder.id,
            price: makerOrder.usdtPricePerUnit,
            payUsdtAmount: needUsdtAmount,
            blockNumber: block.number,
            baseFee: block.basefee
        });

        // 创建吃单
        takerOrderList.push(newTakerOrderDetail);
        // 用户相关的吃单
        userToTakerOrders[msg.sender].push(newTakerOrderDetail.id);

        // 将nete转移给吃单用户的本金钱包(普通用户) or 链上钱包(市商)
        takerIsMarketMaker
            ? IERC20Metadata(nete).safeTransfer(msg.sender, buyNeteQty)
            : IERC20Metadata(nete).safeTransfer(miningMachineAddr, buyNeteQty);

        // 分配 usdt
        if (makerOrder.isMarketMaker) {
            IERC20Metadata(usdt).safeTransfer(
                makerOrder.creator,
                needUsdtAmount
            );
        } else {
            uint256 tenPercentUsdt = (needUsdtAmount * 10) / 100;

            IERC20Metadata(usdt).safeTransfer(
                makerOrder.creator,
                needUsdtAmount - tenPercentUsdt
            );

            _tenPercentProfitDistribution(tenPercentUsdt);
        }

        emit CreateTakerOrder(
            msg.sender,
            buyNeteQty,
            newTakerOrderDetail.id,
            needUsdtAmount
        );
    }

    // 取消挂单
    function cancelNeteSellingMaker(uint256 id) external nonReentrant {
        // require(makerOrderList.length != 0, "No maker orders");
        // require(id <= getMakerOrderListLen() - 1, "invalid Id");
        // uint256 globalIndex = id - 1;
        MakerOrderDetail storage makerOrder = makerOrderList[id];
        address makerOrderOwner = makerOrder.creator;

        // 检查 msg.sender是否是 挂单的owner
        if (msg.sender != makerOrderOwner)
            revert OrderBookSystem__YouAreNotOwnerOfThisMakerOrder();

        // 检查 指定 maker order的 state
        if (makerOrder.status != OrderState.opening)
            revert OrderBookSystem__CurrentMakerOrderIsNotOpening();

        makerOrder.status = OrderState.cancel;

        // 目前的工具方法还不全面
        _modifyUserToOpeningMakerOrders(
            makerOrderOwner,
            makerOrder.statusPosIndex
        );

        _removeMakerOrderIdFromOpeningMakerOrderList(makerOrder.id);

        uint256 nextCancelIndex = userToCancelMakerOrders[makerOrderOwner]
            .length;

        makerOrder.statusPosIndex = nextCancelIndex;

        userToCancelMakerOrders[makerOrderOwner].push(makerOrder.id);

        // 退还 nete
        uint256 refundAmount = makerOrder.remainQtyForSale;

        makerOrder.remainQtyForSale = 0;

        IERC20Metadata(nete).safeTransfer(makerOrderOwner, refundAmount);

        emit CancelMakerOrder(
            makerOrderOwner,
            makerOrder.id,
            makerOrder.statusPosIndex
        );
    }

    // 分配普通用户吃单支付usdt的 10% 收益
    function _tenPercentProfitDistribution(uint256 profit) private {
        uint256 emergencyFund = (profit * 10) / 100;
        uint256 projectOperation = (profit * 40) / 100;
        uint256 projectParty = profit - emergencyFund - projectOperation;

        IERC20Metadata(usdt).safeTransfer(emergencyFundWallet, emergencyFund);
        IERC20Metadata(usdt).safeTransfer(
            projectOperationWallet,
            projectOperation
        );
        IERC20Metadata(usdt).safeTransfer(projectPartyWallet, projectParty);
    }

    // 将 userToOpeningMakerOrders 数组最后一个元素 覆盖 中间指定索引的元素
    function _modifyUserToOpeningMakerOrders(
        address makerOrderOwner,
        uint256 currentIndexInOpening
    ) private {
        // 将makerOrder的 statusId 挪到 userToCompleteMakerOrders
        // 1. 覆盖 userToOpeningMakerOrders 原索引
        uint256 createrOpeningLen = userToOpeningMakerOrders[makerOrderOwner]
            .length;
        uint256 lastElementIndex = createrOpeningLen - 1;
        // 1.1 判断 userToOpeningMakerOrders 长度 >= 1
        // openingLen长度只可能大于等于1

        if (currentIndexInOpening != lastElementIndex) {
            uint256 lastElementId = userToOpeningMakerOrders[makerOrderOwner][
                lastElementIndex
            ];

            // 覆盖， 数组最后一个元素 覆盖 当前索引的元素      抽取的不全面
            userToOpeningMakerOrders[makerOrderOwner][
                currentIndexInOpening // makerOrder.statusPosIndex
            ] = lastElementId;

            // 修改最后一个元素 的 maker order 的 status id
            makerOrderList[lastElementId]
                .statusPosIndex = currentIndexInOpening; // makerOrder.statusPosIndex
        }
        // 弹出最后一个元素
        userToOpeningMakerOrders[makerOrderOwner].pop();
    }

    // 将挂单id从openingMakerOrderList数组中移除
    function _removeMakerOrderIdFromOpeningMakerOrderList(
        uint256 _makerOrderId
    ) private {
        uint256 index = uint256(makerOrderIdInOpeningListIndex[_makerOrderId]);
        uint256 openingMakerOrderListLastIndex = openingMakerOrderList.length -
            1;

        if (index != openingMakerOrderListLastIndex) {
            uint256 lastElement = openingMakerOrderList[
                openingMakerOrderListLastIndex
            ];
            openingMakerOrderList[index] = lastElement;
            makerOrderIdInOpeningListIndex[lastElement] = int256(index);
        }
        openingMakerOrderList.pop();
        makerOrderIdInOpeningListIndex[_makerOrderId] = -1;
    }

    /* =======================================================
                        Getter
    ======================================================= */

    // 获得 已挂单数组 长度
    function getMakerOrderListLen() public view returns (uint256) {
        return makerOrderList.length;
    }

    // 获得 已吃单数组 长度
    function getTakerOrderListLen() public view returns (uint256) {
        return takerOrderList.length;
    }

    // 获得 已完成的挂单数组 长度
    function getCompleteMakerOrderListLen() public view returns (uint256) {
        return completeMakerOrderList.length;
    }

    // 获得 正在挂单的订单id数组 长度
    function getOpeningMakerOrderListLen() public view returns (uint256) {
        return openingMakerOrderList.length;
    }

    // 获得 用户吃单数组 长度
    function getUserToTakerOrdersLen(
        address user
    ) public view returns (uint256) {
        return userToTakerOrders[user].length;
    }

    // 获得用户处在不同状态下的挂单数组
    function getUserToDiffStateMakerOrders(
        address user,
        OrderState state
    ) public view returns (uint256[] memory) {
        if (state == OrderState.opening) {
            return userToOpeningMakerOrders[user];
        } else if (state == OrderState.complete) {
            return userToCompleteMakerOrders[user];
        } else {
            return userToCancelMakerOrders[user];
        }
    }

    // 获得用户身份挂单nete的价格
    function getUserSellNetePrice(address user) public view returns (uint256) {
        return marketMakerAllow[user] ? marketMakerPrice : generalPrice;
    }

    // 获得用户处在不同状态下的挂单数组长度
    function getUserToDiffStateMakerOrdersLen(
        address user,
        OrderState state
    ) public view returns (uint256) {
        if (state == OrderState.opening) {
            return userToOpeningMakerOrders[user].length;
        } else if (state == OrderState.complete) {
            return userToCompleteMakerOrders[user].length;
        } else {
            return userToCancelMakerOrders[user].length;
        }
    }

    // 获得指定用户不同状态下的挂单详情集合
    function getUserDiffStateMakerOrders(
        address user,
        uint256 start,
        uint256 limit,
        OrderState state
    ) public view returns (MakerOrderDetail[] memory, uint256) {
        uint256 maxLimit = 100;
        if (limit > maxLimit) limit = maxLimit;

        uint256[] storage orderIndexesArr;

        if (state == OrderState.opening) {
            orderIndexesArr = userToOpeningMakerOrders[user];
        } else if (state == OrderState.complete) {
            orderIndexesArr = userToCompleteMakerOrders[user];
        } else if (state == OrderState.cancel) {
            orderIndexesArr = userToCancelMakerOrders[user];
        } else {
            revert("Invalid order state");
        }

        uint256 len = orderIndexesArr.length;

        if (start >= len) {
            return (new MakerOrderDetail[](0), len);
        }

        uint256 end = start + limit;

        if (end > len) end = len;

        uint256 size = end - start;

        MakerOrderDetail[] memory orderDetails = new MakerOrderDetail[](size);

        uint256 orderIndex;
        for (uint256 i = 0; i < size; ) {
            orderIndex = orderIndexesArr[start + i];
            orderDetails[i] = makerOrderList[orderIndex];
            //     少一次 overflow check, 节点执行更快（虽然是 view）
            unchecked {
                ++i;
            }
        }

        return (orderDetails, len);
    }

    // 获得当前处于 opening 状态的挂单详情列表
    function getOpeningMakerOrders(
        uint256 start,
        uint256 limit
    ) public view returns (MakerOrderDetail[] memory, uint256) {
        /**
         * 编译器会把它当成一个 storage 引用指针（类似别名）
         * 后面访问：orderIndexesArr[x] 就不用反复解析原变量路径了
         */
        uint256[] storage orderIndexesArr = openingMakerOrderList;

        uint256 len = orderIndexesArr.length;

        if (start >= len) {
            return (new MakerOrderDetail[](0), len);
        }

        uint256 end = start + limit;

        if (end > len) end = len;

        uint256 size = end - start;

        MakerOrderDetail[] memory orderDetails = new MakerOrderDetail[](size);

        uint256 orderIndex;
        for (uint256 i = 0; i < size; ) {
            orderIndex = orderIndexesArr[start + i];
            orderDetails[i] = makerOrderList[orderIndex];
            //     少一次 overflow check, 节点执行更快（虽然是 view）
            unchecked {
                ++i;
            }
        }

        return (orderDetails, len);
    }

    // 获得指定用户的吃单详情集合
    function getUserTakerOrders(
        address user,
        uint256 start,
        uint256 limit
    ) public view returns (TakerOrderDetail[] memory, uint256) {
        uint256[] storage orderIndexesArr = userToTakerOrders[user];

        uint256 len = orderIndexesArr.length;

        if (start >= len) {
            return (new TakerOrderDetail[](0), len);
        }

        uint256 end = start + limit;

        if (end > len) end = len;

        uint256 size = end - start;

        TakerOrderDetail[] memory orderDetails = new TakerOrderDetail[](size);

        uint256 orderIndex;

        for (uint256 i = 0; i < size; ) {
            orderIndex = orderIndexesArr[start + i];
            orderDetails[i] = takerOrderList[orderIndex];
            unchecked {
                ++i;
            }
        }

        return (orderDetails, len);
    }
}
