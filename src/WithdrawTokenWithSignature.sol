// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManagementTemplate} from "./AccessManagementTemplate.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title 通用提币合约模板
 * @author Xavier
 * @notice 继承该合约的子合约，无需再次继承AccessManagementTemplate 和 Ownable 权限管理合约
 */
abstract contract WithdrawTokenWithSignature is AccessManagementTemplate {
    using Strings for uint256;
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // 提币订单id状态
    struct WithdrawalOrderIdStatus {
        uint256 orderId;
        bool active;
    }

    // 提币订单详情
    struct WithdrawOrderPo {
        uint8 enableFlag; // 0 空订单  1 有效
        uint40 createTimestamp; // 创建时间
        address user; // 提币用户
        uint256 withdrawalQty; // 提币数量
        uint256 id; // 对应位于 withdrawOrderArray 中的索引
        uint256 orderId; // 后端传的 订单id
        uint256 blockNumber; // 区块数
        uint256 baseFee; // 基础gas费
    }

    // 提币开关
    bool public enableWithdraw = true;
    // 要提的token，设置为 address(0),表示要体现的是原生token
    // address public withdrawalToken = 0xdA25a2B5b4d8871D11d42F678931597057FB07C3;
    address public withdrawalToken;
    // 签名地址
    // address public withdrawSigner = 0x4eB1662C9Fe7a89E6cE7260B5F2DE6F9A3978f89;
    address public withdrawSigner = 0x47724e92f071D7809fe6A1eb11BBa99cE17C1E63; // wallet 6
    // 一共提出的数量
    uint256 public globalWithdrawQty;
    // 提币订单列表
    WithdrawOrderPo[] public withdrawOrderArray;
    // 特定用户提币的数量
    mapping(address => uint256) public userWithdrawQty;
    // 用户关联的 id
    mapping(address => uint256[]) public userToIds;
    // 同一个订单id不可重复提币
    mapping(uint256 => bool) public hasTheWithdrawalOrderIdBeenUserd;

    // 提币订单 id 对应的 withdrawOrderArray 下标
    mapping(uint256 => uint256) public orderIdToArrayIndex;

    // 提币黑名单
    mapping(address => bool) public blackWithdrawalWallet;

    error WithdrawTokenWithSignature__WithdrawalIsNotOpen();
    error WithdrawTokenWithSignature__YouAreInBlackList();
    error WithdrawTokenWithSignature__OrderAlreadyUsed();
    error WithdrawTokenWithSignature__SignatureVerificationFailed();
    error WithdrawTokenWithSignature__InsufficientTokenInContract();

    event WithdrawnToken(
        uint256 indexed orderId,
        address indexed user,
        uint256 indexed amount
    );

    receive() external payable {}

    constructor(address _withdrawToken) {
        withdrawalToken = _withdrawToken;
    }

    // 设置要提币的token
    function setWithdrawalToken(address _tokenAddr) public onlyAdmin {
        withdrawalToken = _tokenAddr;
    }

    // 设置 签名者
    function setWithdrawSigner(address _newSigner) public onlyAdmin {
        withdrawSigner = _newSigner;
    }

    // 设置提币开关
    function setEnableWithdraw(bool _enable) public onlyManager {
        enableWithdraw = _enable;
    }

    // 设置黑名单
    function setBlackList(address _wallet, bool _auth) public onlyManager {
        blackWithdrawalWallet[_wallet] = _auth;
    }

    /**
     * 钱包提现
     * 传入指定的提现订单ID，提现金额（需要乘于数据位），提现签名，来实现提现功能。提现时，从合约向调用的钱包
     * 转入指定数量的币。币的类型取决于withdrawalToken，签名用withdrawSigner 这个钱包来验签。
     * @param _orderId 传入后台返回的 提币订单id
     * @param _withdrawalQty  传入后台返回的要提币的数量
     * @param signature 传入后台返回的消息签名，消息格式 "用户地址(全小写);合约地址(全小写);提币数量;提币订单id"
     */
    function withdrawToken(
        uint256 _orderId,
        uint256 _withdrawalQty,
        bytes calldata signature
    ) public {
        if (!enableWithdraw)
            revert WithdrawTokenWithSignature__WithdrawalIsNotOpen();

        if (blackWithdrawalWallet[msg.sender])
            revert WithdrawTokenWithSignature__YouAreInBlackList();

        string memory message = string.concat(
            Strings.toHexString(msg.sender),
            ";",
            Strings.toHexString(address(this)),
            ";",
            _withdrawalQty.toString(),
            ";",
            _orderId.toString()
        );

        bytes memory addEthHead = abi.encodePacked(
            "\x19Ethereum Signed Message:\n",
            Strings.toString(bytes(message).length),
            message
        );

        bytes32 ethSignedMsgHash = keccak256(addEthHead);

        bool verifyResult = withdrawSigner ==
            ECDSA.recover(ethSignedMsgHash, signature);

        if (!verifyResult) {
            if (debugMode) {
                emit FailMsg(
                    DebugConcatObj(
                        "Verify0: ",
                        msg.sender,
                        address(this),
                        _withdrawalQty,
                        _orderId
                    )
                );
                return;
            }

            revert WithdrawTokenWithSignature__SignatureVerificationFailed();
        }

        if (hasTheWithdrawalOrderIdBeenUserd[_orderId])
            revert WithdrawTokenWithSignature__OrderAlreadyUsed();

        uint256 tokenAmountInContract;
        // 检查合约里的token数量是否足以支付用户提取数量
        if (withdrawalToken == address(0)) {
            tokenAmountInContract = address(this).balance;
        } else {
            tokenAmountInContract = IERC20(withdrawalToken).balanceOf(
                address(this)
            );
        }

        if (tokenAmountInContract < _withdrawalQty)
            revert WithdrawTokenWithSignature__InsufficientTokenInContract();

        uint256 latestId = withdrawOrderArray.length;

        // 创建提现订单
        WithdrawOrderPo memory latestWithdrawOrder = WithdrawOrderPo({
            enableFlag: 1,
            createTimestamp: uint40(block.timestamp),
            user: msg.sender,
            withdrawalQty: _withdrawalQty,
            id: latestId,
            orderId: _orderId,
            blockNumber: block.number,
            baseFee: block.basefee
        });

        globalWithdrawQty += _withdrawalQty;

        userWithdrawQty[msg.sender] += _withdrawalQty;

        userToIds[msg.sender].push(latestId);

        hasTheWithdrawalOrderIdBeenUserd[_orderId] = true;

        orderIdToArrayIndex[_orderId] = latestId;

        withdrawOrderArray.push(latestWithdrawOrder);

        if (withdrawalToken == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: _withdrawalQty}(
                ""
            );
            require(success, "Native transfer failed");
        } else {
            IERC20(withdrawalToken).safeTransfer(msg.sender, _withdrawalQty);
        }

        emit WithdrawnToken(_orderId, msg.sender, _withdrawalQty);
    }

    /**
     * 返回提现订单数组长度
     */
    function getWithdrawOrderArrayLen() public view returns (uint256) {
        return withdrawOrderArray.length;
    }

    /**
     * 返回用户的提币订单数组长度
     * @param user 用户地址
     */
    function getUserToIdsLength(address user) public view returns (uint256) {
        return userToIds[user].length;
    }

    /**
     * 返回对应的 提币订单id 是否已经使用的 数组
     * @param _orderIds 要查询的 提币订单id数组
     */
    function batchGetWithdrawalOrderIdUsedStatus(
        uint256[] calldata _orderIds
    ) public view returns (WithdrawalOrderIdStatus[] memory result) {
        uint256 len = _orderIds.length;

        result = new WithdrawalOrderIdStatus[](len);

        for (uint256 i = 0; i < len; ) {
            result[i] = WithdrawalOrderIdStatus({
                orderId: _orderIds[i],
                active: hasTheWithdrawalOrderIdBeenUserd[_orderIds[i]]
            });

            unchecked {
                ++i;
            }
        }
    }

    /**
     * 获取当前链的id
     */
    function getChainId() public view returns (uint256) {
        return block.chainid;
    }
}
