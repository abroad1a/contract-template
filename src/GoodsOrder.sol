// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessManagementTemplate} from "./AccessManagementTemplate.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// GoodsOrder
contract GoodsOrder is AccessManagementTemplate, ReentrancyGuard {
    /* =======================================================
                        Type Declarations
    ======================================================= */

    using SafeERC20 for IERC20Metadata;

    using Math for uint256;
    // 商品信息的结构体
    struct CnfGoodsInfoPo {
        uint8 enableFlag; // 数据是否有效。 0 空对象  1 有效  2 无效     可修改
        uint8 status; // 激活状态。   1代表上架; 2代表下架; 3代表隐藏    可修改
        uint16 id; //  跟 cnfGoodsInfoPoList 的索引一致
        uint16 feeRatio; // 手续费  0代表没有手续费        可修改
        uint40 createTimestamp; // 记录产生时间
        address creator; // 创建者
        uint256 price; // 商品价格             可修改
        uint256 soldQty; // 已卖出供应量
        int256 maxSupply; // 商品最大供应量   负数表示不限制供应量   可修改
        int256 perWalletLimit; //  单钱包最大购买量   负数表示不限制购买量  可修改
        string name; // 商品名称(少于等于80个字符)
        string description; // 商品描述(少于等于80个字符)
    }

    // 用户产生的订单结构体
    struct UsrOrderPo {
        uint8 enableFlag; // 数据是否有效。 0 空对象  1 有效  2 无效     可修改
        uint16 goodsId; // 商品类型id。依赖 CnfGoodsInfoPo.id
        uint40 createTimestamp; // 记录产生时间
        address wallet; // 用户钱包地址
        uint256 id; // 订单id，对应usrOrderPoList的下标
        uint256 buyQty; // 购买该类型商品数量。一般每次只购买一个
        uint256 payAmount; // 付款金额。 一般为USDT。这个金额一般都是相对来讲的  usdt -> nete数量  nete -> 矿机数量
        uint256 feeAmount; // 支付的手续费
        uint256 upperRewardAmount; // 支付给上级的奖励
        uint256 blockNumber; // 区块数
        uint256 baseFee; // 基础gas费
    }

    struct UpperInfoPo {
        uint8 enableFlag; // 是否有效数据
        address upper; // 上级地址
        uint256 index; // 下级地址 位于 上级对应的 下级地址数组 当中的索引
    }

    /* =======================================================
                        State Variables
    ======================================================= */

    // 手续费钱包地址   admin
    address public feeWallet;

    // 国库钱包地址    admin
    address public treasury;

    // 支付购买商品使用的token地址，如果是address(0)，表示使用原生token进行支付
    address public payToken;

    // 直推奖励系数  manager 修改
    uint16 public upperRewardRatio;

    // 一个钱包地址可购买的所有商品的数量上限   -1表示没有限制
    int256 public userBuyAllLimit;

    // 上级必须有购买才有直推奖励
    bool public upDirectProfitMustBuy;

    // 是否开放 售卖
    bool public saleOpen;

    // 商品类型 列表  storage变量
    CnfGoodsInfoPo[] public cnfGoodsInfoPoList;

    // 商品订单的数组  storage变量
    UsrOrderPo[] public usrOrderPoList;

    // 已绑定上级的钱包地址数组
    address[] public bindingUpperWalletList;

    // 用户购买的所有商品的数量
    mapping(address => uint256) public userBuyAllQty;

    // 用户已购买某种商品数量    storage变量
    mapping(address => mapping(uint256 => uint256)) public userToPurchasedQty;

    //地址上级映射
    mapping(address => UpperInfoPo) public addressRelationMap;

    // 上级地址相关联的下级地址数组
    mapping(address => address[]) public upperToLowerArr;

    // 用户相关的购买订单的记录  storage变量
    mapping(address => uint256[]) public usrToOrders;

    // 各类商品 卖出总量查询
    mapping(uint16 => uint256) private goodsSaleTotalAmount;

    //  key 为 s_cnfGoodsInfoPoList 下标， 子mapping的key 为商品扩展字段， 子mapping的value为扩展值
    mapping(uint256 => mapping(string => string)) public extraData; // manager

    /* =======================================================
                        Events
    ======================================================= */
    // 创建商品类型事件
    event CreateCnfGoodsInfoPo(uint16 indexed id, address indexed creator);

    // 购买商品事件
    event BuyGoods(
        uint256 indexed orderId,
        address indexed creator,
        uint16 indexed id
    );
    // 用户设置上级事件
    event UserSetUpper(address indexed wallet, address indexed upper);

    // manager重置上级事件
    event ResetUpper(
        address indexed manager,
        address indexed user,
        address indexed upper
    );

    // manager 设置 手续费率事件
    event SetGoodsFeeRatio(
        address indexed manager,
        uint16 indexed goodsId,
        uint16 indexed newFeeRatio
    );

    // manager 设置商品类型数据有效性事件
    event SetGoodsEnableFlag(
        address indexed manager,
        uint16 indexed goodsId,
        uint8 indexed currentFlag
    );
    // manager 设置商品类型 状态事件
    event SetGoodsStatus(
        address indexed manager,
        uint16 indexed goodsId,
        uint8 indexed currentStatus
    );

    // manager 设置商品价格事件
    event SetGoodsPrice(
        address indexed manager,
        uint16 indexed goodsId,
        uint256 indexed newPrice
    );

    // manager 设置商品最大供应量事件
    event SetGoodsMaxSupply(
        address indexed manager,
        uint16 indexed goodsId,
        int256 indexed newMaxSupply
    );

    // manager 设置商品单钱包地址可购买上限事件
    event SetGoodsPerWalletLimit(
        address indexed manager,
        uint16 indexed goodsId,
        int256 indexed newPerWalletLimit
    );

    // manager 设置用户购买订单数据有效性事件
    event SetUsrOrderEnableFlag(
        address indexed manager,
        uint256 indexed orderId,
        uint8 indexed currentFlag
    );

    /* =======================================================
                        Errors
    ======================================================= */
    // 未开放售卖
    error GoodsOrder__SaleIsNotOpen();
    // 此商品信息已失效
    error GoodsOrder__ThisGoodsIsNotAvailable();
    // 此商品已下架
    error GoodsOrder__ThisGoodsIsNotListed();
    // 购买数量大于此商品剩余供应量
    error GoodsOrder__ExceedingThePurchaseLimitQuota();
    // 购买数量大于系统设定的用户总购买数量的上限
    error GoodsOrder__ExceedingTheUserBuyAllLimit();

    // 如果用户要购买数量 超过了 用户地址剩余可购买数量额度
    error GoodsOrder__TheCurrentUserPurchaseLimitHasBeenReached();

    // 用户授权额度不足
    error GoodsOrder__InsufficientPayTokenAllowance();
    // 用户钱包余额不足
    error GoodsOrder__InsufficientPayTokenBalance();

    // 用户已绑定过上级
    error GoodsOrder__TheUpperHasAlreadyBeenSet();
    // 无效的 cnfGoodsInfoPoList 索引 输入
    error GoodsOrder__InvalidGoodsInfoId();

    // 输入的最大供应量不应该小于 已卖出的商品数量
    error GoodsOrder__InputMaxSupplyLessThanCurrentSoldSupply();

    // 不能自绑
    error GoodsOrder__CanNotBindYourselfAsUpper();

    /* =======================================================
                        Modifiers
    ======================================================= */

    // 检查输入的 cnfGoodsInfoPoList 的 索引是否超出长度范围
    modifier isValidGoodsId(uint16 _id) {
        if (_id >= cnfGoodsInfoPoList.length)
            revert GoodsOrder__InvalidGoodsInfoId();
        _;
    }

    /* =======================================================
                            Functions
    ======================================================= */

    /* ------------------------------------------------------
                    Initializer/Constructor
    ------------------------------------------------------ */

    constructor() {
        // BSC Testnet
        feeWallet = 0x48330A28d09161d9DEca84eaf841EDbE1a0c508d; // wallet 2
        treasury = 0x50FaBeB2BA24b2022F2bfffE3B7FEfa0657dE562; // wallet 3
        payToken = 0xacD944e910952c020eb129C50921f180c62c3291; // USDx5 18位
        upDirectProfitMustBuy = false;
        saleOpen = true;
        userBuyAllLimit = 1;

        // BSC 正式链
        // feeWallet = 0xC039655a85eF3E0DE500FFd237Eff8676f52240E;
        // treasury = 0xC039655a85eF3E0DE500FFd237Eff8676f52240E;
        // payToken = 0x55d398326f99059fF775485246999027B3197955;
    }

    receive() external payable {}

    // 配置商品  manager权限
    function addCnfGoodsInfoPo(
        string calldata _name,
        string calldata _description,
        uint256 _price,
        int256 _maxSupply,
        int256 _perWalletLimit,
        uint16 _feeRatio,
        uint8 _status
    ) external onlyManager {
        require(_price != 0, "Price can't be Zero");
        require(_feeRatio < 10000, "Invalid input fee");

        uint256 nextId = cnfGoodsInfoPoList.length;

        CnfGoodsInfoPo memory newCnfGoodsInfoPo = CnfGoodsInfoPo({
            enableFlag: 1,
            status: _status,
            createTimestamp: uint40(block.timestamp),
            feeRatio: _feeRatio,
            creator: msg.sender,
            id: uint16(nextId),
            price: _price,
            maxSupply: _maxSupply,
            soldQty: 0,
            perWalletLimit: _perWalletLimit,
            name: _name,
            description: _description
        });

        cnfGoodsInfoPoList.push(newCnfGoodsInfoPo);

        emit CreateCnfGoodsInfoPo(
            newCnfGoodsInfoPo.id,
            newCnfGoodsInfoPo.creator
        );
    }

    // extraData
    // 配置商品 扩展属性
    function setGoodsInfoExtra(
        uint16 _id,
        string calldata _key,
        string calldata _value
    ) external onlyManager {
        if (cnfGoodsInfoPoList[_id].enableFlag != 1)
            revert GoodsOrder__ThisGoodsIsNotAvailable();
        extraData[_id][_key] = _value;
    }

    // 配置直推奖励系数
    function setUpperRewardRatio(uint16 _rewardRatio) external onlyManager {
        upperRewardRatio = _rewardRatio;
    }

    // 购买商品
    function buyGoods(
        uint16 _id,
        uint256 _buyQty
    ) external payable nonReentrant {
        if (!saleOpen) revert GoodsOrder__SaleIsNotOpen();

        if (cnfGoodsInfoPoList[_id].enableFlag != 1)
            revert GoodsOrder__ThisGoodsIsNotAvailable();

        if (cnfGoodsInfoPoList[_id].status != 1)
            revert GoodsOrder__ThisGoodsIsNotListed();

        // 如果商品的供应量不是无限
        if (
            cnfGoodsInfoPoList[_id].maxSupply >= 0 &&
            (cnfGoodsInfoPoList[_id].soldQty + _buyQty) >
            uint256(cnfGoodsInfoPoList[_id].maxSupply)
        ) {
            revert GoodsOrder__ExceedingThePurchaseLimitQuota();
        }

        // 如果用户的总购买数量不是无限
        if (
            userBuyAllLimit >= 0 &&
            (userBuyAllQty[msg.sender] + _buyQty) > uint256(userBuyAllLimit)
        ) {
            revert GoodsOrder__ExceedingTheUserBuyAllLimit();
        }

        // 如果用户的可购买数量不是无限
        if (
            cnfGoodsInfoPoList[_id].perWalletLimit >= 0 &&
            (userToPurchasedQty[msg.sender][_id] + _buyQty) >
            uint256(cnfGoodsInfoPoList[_id].perWalletLimit)
        ) {
            revert GoodsOrder__TheCurrentUserPurchaseLimitHasBeenReached();
        }

        // 计算购买要支付的token 数量
        uint256 needPayAmount = cnfGoodsInfoPoList[_id].price * _buyQty;

        // 判断 用户 s_payToken 授权 和 钱包余额

        if (payToken == address(0)) {
            // 原生币支付
            require(msg.value == needPayAmount, "Invalid native token amount");
        } else {
            require(msg.value == 0, "msg.value not allowed");
            if (
                IERC20Metadata(payToken).allowance(msg.sender, address(this)) <
                needPayAmount
            ) revert GoodsOrder__InsufficientPayTokenAllowance();

            if (IERC20Metadata(payToken).balanceOf(msg.sender) < needPayAmount)
                revert GoodsOrder__InsufficientPayTokenBalance();

            IERC20Metadata(payToken).safeTransferFrom(
                msg.sender,
                address(this),
                needPayAmount
            );
        }

        uint256 needFeeAmount = 0;
        // 计算包含的手续费
        if (cnfGoodsInfoPoList[_id].feeRatio != 0) {
            needFeeAmount =
                (needPayAmount * uint256(cnfGoodsInfoPoList[_id].feeRatio)) /
                10000;

            _transferPayToken(feeWallet, needFeeAmount);
            // IERC20Metadata(payToken).safeTransfer(feeWallet, needFeeAmount);
        }

        // 计算上级收益
        uint256 upperReward = 0;
        address upper = addressRelationMap[msg.sender].upper;
        if (upper != address(0)) {
            bool eligible = true;

            if (upDirectProfitMustBuy) {
                eligible = usrToOrders[upper].length > 0;
            }

            if (eligible && upperRewardRatio != 0) {
                upperReward =
                    (needPayAmount * uint256(upperRewardRatio)) /
                    10000;

                _transferPayToken(upper, upperReward);
                // IERC20Metadata(payToken).safeTransfer(upper, upperReward);
            }
        }

        // 卖出商品收入 扣除 手续费 和 上级奖励后 发给国库钱包

        _transferPayToken(
            treasury,
            needPayAmount - needFeeAmount - upperReward
        );
        // IERC20Metadata(payToken).safeTransfer(
        //     treasury,
        //     needPayAmount - needFeeAmount - upperReward
        // );

        // 用户符合购买条件
        uint256 nextId = usrOrderPoList.length;

        UsrOrderPo memory newUsrOrderPo = UsrOrderPo({
            enableFlag: 1,
            goodsId: _id,
            createTimestamp: uint40(block.timestamp),
            wallet: msg.sender,
            id: nextId,
            buyQty: _buyQty,
            payAmount: needPayAmount,
            feeAmount: needFeeAmount,
            upperRewardAmount: upperReward,
            blockNumber: block.number,
            baseFee: block.basefee
        });

        userBuyAllQty[msg.sender] += _buyQty;

        goodsSaleTotalAmount[_id] += needPayAmount;

        usrOrderPoList.push(newUsrOrderPo);

        cnfGoodsInfoPoList[_id].soldQty += _buyQty;
        userToPurchasedQty[msg.sender][_id] += _buyQty;
        usrToOrders[msg.sender].push(nextId);

        emit BuyGoods(newUsrOrderPo.id, msg.sender, _id);
    }

    function _transferPayToken(address to, uint256 amount) internal {
        if (amount == 0) return;

        if (payToken == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");

            require(success, "Native transfer failed");
        } else {
            IERC20Metadata(payToken).safeTransfer(to, amount);
        }
    }

    // 设置上级函数  已经设置了上级用户不可再次设置
    function setUpper(address _upper) external {
        require(_upper != address(0), "Invalid address");
        if (_upper == msg.sender)
            revert GoodsOrder__CanNotBindYourselfAsUpper();

        if (addressRelationMap[msg.sender].upper != address(0))
            revert GoodsOrder__TheUpperHasAlreadyBeenSet();

        uint256 nextIndex = upperToLowerArr[_upper].length;

        UpperInfoPo memory bindInfo = UpperInfoPo({
            upper: _upper,
            index: nextIndex,
            enableFlag: 1
        });

        addressRelationMap[msg.sender] = bindInfo;

        upperToLowerArr[_upper].push(msg.sender);

        bindingUpperWalletList.push(msg.sender);

        emit UserSetUpper(msg.sender, _upper);
    }

    // 重置上级函数 manager权限
    function resetUpper(address _user, address _newUpper) external onlyManager {
        require(_newUpper != address(0), "Input can't be 0 address");

        if (_newUpper == _user) revert GoodsOrder__CanNotBindYourselfAsUpper();

        uint256 newUpperToLowerArrLen = upperToLowerArr[_newUpper].length;

        // 如果 该用户从未绑定过上级地址
        if (addressRelationMap[_user].enableFlag == 0) {
            addressRelationMap[_user].enableFlag = 1;
            bindingUpperWalletList.push(_user);
        } else {
            // 如果该用户绑定过上级地址
            // 修改该用户 原上级地址 对应的 下级地址 数组
            uint256 oldIndex = addressRelationMap[_user].index;
            address oldUpper = addressRelationMap[_user].upper;
            uint256 oldUpperToLowerArrLastIndex = upperToLowerArr[oldUpper]
                .length - 1;

            if (oldIndex != oldUpperToLowerArrLastIndex) {
                address lastLowerAddr = upperToLowerArr[oldUpper][
                    oldUpperToLowerArrLastIndex
                ];
                // 覆盖
                upperToLowerArr[oldUpper][oldIndex] = lastLowerAddr;

                addressRelationMap[lastLowerAddr].index = oldIndex;
            }
            upperToLowerArr[oldUpper].pop();
        }

        addressRelationMap[_user].upper = _newUpper;
        addressRelationMap[_user].index = newUpperToLowerArrLen;

        upperToLowerArr[_newUpper].push(_user);

        emit ResetUpper(msg.sender, _user, _newUpper);
    }

    //  设置是否上级必须有购买，才能拿直推奖励
    function setUpDirectProfitMustBuy(bool _enable) external onlyManager {
        upDirectProfitMustBuy = _enable;
    }

    function setSaleOpen(bool _enable) external onlyManager {
        saleOpen = _enable;
    }

    // admin 设置 接收手续费钱包
    function setFeeWallet(address _newFeeWallet) external onlyAdmin {
        feeWallet = _newFeeWallet;
    }

    // admin 设置 国库钱包
    function setTreasury(address _newTreasury) external onlyAdmin {
        treasury = _newTreasury;
    }

    // admin 设置购买商品支付的token
    function setPayToken(address _newPayToken) external onlyAdmin {
        payToken = _newPayToken;
    }

    // manager设置已产生购买订单是否有效
    function setUsrOrderEnableFlag(
        uint256 _id,
        uint8 _enableFlag
    ) external onlyManager {
        require(_id <= usrOrderPoList.length - 1, "Invalid Id");
        require(_enableFlag != 0, "Can not be 0");
        require(_enableFlag == 1 || _enableFlag == 2, "Invalid Params");
        usrOrderPoList[_id].enableFlag = _enableFlag;
        emit SetUsrOrderEnableFlag(msg.sender, _id, _enableFlag);
    }

    // 修改已有商品的名称
    function setSpecifyGoodsName(
        uint16 _id,
        string calldata _newName
    ) external isValidGoodsId(_id) onlyManager {
        cnfGoodsInfoPoList[_id].name = _newName;
    }

    // 修改已有商品的描述
    function setSpecifyGoodsDescription(
        uint16 _id,
        string calldata _newDescription
    ) external isValidGoodsId(_id) onlyManager {
        cnfGoodsInfoPoList[_id].description = _newDescription;
    }

    // manager 设置商品 的手续费率
    function setSpecifyGoodsFeeRatio(
        uint16 _id,
        uint16 _feeRatio
    ) external isValidGoodsId(_id) onlyManager {
        require(_feeRatio < 10000, "Invalid input fee");

        cnfGoodsInfoPoList[_id].feeRatio = _feeRatio;

        emit SetGoodsFeeRatio(msg.sender, _id, _feeRatio);
    }

    // manager 设置商品类型信息的有效性
    function setSpecifyGoodsEnableFlag(
        uint16 _id,
        uint8 _enableFlag
    ) external isValidGoodsId(_id) onlyManager {
        require(_enableFlag == 1 || _enableFlag == 2, "Invalid data");
        cnfGoodsInfoPoList[_id].enableFlag = _enableFlag;
        emit SetGoodsEnableFlag(msg.sender, _id, _enableFlag);
    }

    // manager 设置商品类型 的 上架/下架/隐藏 状态
    function setSpecifyGoodsStatus(
        uint16 _id,
        uint8 _status
    ) external isValidGoodsId(_id) onlyManager {
        require(_status == 1 || _status == 2 || _status == 3, "Invalid data");
        cnfGoodsInfoPoList[_id].status = _status;
        emit SetGoodsStatus(msg.sender, _id, _status);
    }

    // manager 设置商品的价格
    function setSpecifyGoodsPrice(
        uint16 _id,
        uint256 _price
    ) external isValidGoodsId(_id) onlyManager {
        require(_price != 0, "Price can't be 0");
        cnfGoodsInfoPoList[_id].price = _price;
        emit SetGoodsPrice(msg.sender, _id, _price);
    }

    // manager 设置商品的最大供应量
    function setSpecifyGoodsMaxSupply(
        uint16 _id,
        int256 _maxSupply
    ) external isValidGoodsId(_id) onlyManager {
        if (
            _maxSupply >= 0 &&
            uint256(_maxSupply) < cnfGoodsInfoPoList[_id].soldQty
        ) revert GoodsOrder__InputMaxSupplyLessThanCurrentSoldSupply();

        cnfGoodsInfoPoList[_id].maxSupply = _maxSupply;

        emit SetGoodsMaxSupply(msg.sender, _id, _maxSupply);
    }

    // manager 设置 单钱包地址可购买商品数量的限制
    function setSpecifyGoodsPerWalletLimit(
        uint16 _id,
        int256 _perWalletLimit
    ) external isValidGoodsId(_id) onlyManager {
        cnfGoodsInfoPoList[_id].perWalletLimit = _perWalletLimit;
        emit SetGoodsPerWalletLimit(msg.sender, _id, _perWalletLimit);
    }

    // 设置 一个钱包 地址对所有商品的可购买数量
    function setUserBuyAllLimit(int256 _qty) external onlyManager {
        userBuyAllLimit = _qty;
    }

    // 获取商品类型数组的长度
    function getCnfGoodsInfoPoListLen() public view returns (uint256) {
        return cnfGoodsInfoPoList.length;
    }

    // 获取商品订单数组的长度
    function getUsrOrderPoListLen() public view returns (uint256) {
        return usrOrderPoList.length;
    }

    // 获取绑定上级的地址列表长度
    function getBindingUpperWalletListLen() public view returns (uint256) {
        return bindingUpperWalletList.length;
    }

    // 获取用户相关的 订单id 的数量
    function getUserToOrdersLen(address wallet) public view returns (uint256) {
        return usrToOrders[wallet].length;
    }

    // 获取用户相关最新的 订单id 和 购买的商品id
    function getUserLatestOrderIdAndGoodsId(
        address wallet
    ) public view returns (uint256 orderId, uint16 goodsId, uint8 enableFlag) {
        if (usrToOrders[wallet].length != 0) {
            uint256 userLatestOrderIdIndex = usrToOrders[wallet].length - 1;
            orderId = usrToOrders[wallet][userLatestOrderIdIndex];
            goodsId = usrOrderPoList[orderId].goodsId;
            enableFlag = 1;
        } else {
            orderId = 0;
            goodsId = 0;
            enableFlag = 0;
        }
    }

    // 查询各类商品的销售总额
    function getGoodsSaleTotalAmount(
        uint16 _id
    ) public view isValidGoodsId(_id) returns (uint256) {
        return goodsSaleTotalAmount[_id];
    }

    function getUpperToLowerArrLen(
        address _upper
    ) public view returns (uint256) {
        return upperToLowerArr[_upper].length;
    }

    /**
     * 获取当前链的id
     */
    function getChainId() public view returns (uint256) {
        return block.chainid;
    }
}
