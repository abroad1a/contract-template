// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// 继承该合约的合约不需要在引入Ownable.sol
abstract contract AccessManagementTemplate is Ownable {
    using Strings for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    // 定义集合
    EnumerableSet.AddressSet private adminSet;
    EnumerableSet.AddressSet private managerSet;

    // 调试模式开关
    bool public debugMode = false;

    string public name;

    // 调用者非此合约owner
    error AccessTemplate__NoOwnerPrivileges();
    // 调用者非此合约admin
    error AccessTemplate__NoAdminPrivileges();
    // 调用者非manager
    error AccessTemplate__NoManagerPrivileges();
    // 调用者非此合约owner 和 admin
    error AccessTemplate__NoOwnerAndAdminPrivileges();

    // 条件判断为false触发失败事件
    event FailMsg(string failMsg);

    modifier onlyAdmin() {
        if (!setIsContains(1, msg.sender)) {
            revert AccessTemplate__NoAdminPrivileges();
        }
        _;
    }

    modifier onlyManager() {
        if (!setIsContains(2, msg.sender)) {
            revert AccessTemplate__NoManagerPrivileges();
        }
        _;
    }

    constructor(string memory contractName) {
        name = contractName;
    }

    function setContractName(string calldata newName) public virtual onlyAdmin {
        name = newName;
    }

    // 调试用
    function DebugConcatObj(
        string memory tag,
        address addr1,
        address addr2,
        uint256 amount1,
        uint256 amount2
    ) internal pure returns (string memory str) {
        str = string.concat(
            tag,
            ",",
            Strings.toHexString(addr1),
            ",",
            Strings.toHexString(addr2),
            ",",
            amount1.toString(),
            ",",
            amount2.toString()
        );
    }

    function switchDebugMode() public virtual onlyOwner {
        debugMode = !debugMode;
    }

    // roleType  1: 添加admin   2：添加manager
    function addUserToSet(uint8 roleType, address userWallet) public virtual {
        require(userWallet != address(0), "Invalid address");
        if (roleType == 1) {
            if (msg.sender != owner() && !adminSet.contains(msg.sender)) {
                if (debugMode) {
                    emit FailMsg(
                        DebugConcatObj("AddSet1:", msg.sender, owner(), 0, 0)
                    );
                    return;
                }
                revert AccessTemplate__NoOwnerPrivileges();
            }
            adminSet.add(userWallet);
            return;
        }

        if (roleType == 2) {
            if (!adminSet.contains(msg.sender) && msg.sender != owner()) {
                if (debugMode) {
                    emit FailMsg(
                        DebugConcatObj("AddSet2:", msg.sender, owner(), 0, 0)
                    );
                    return;
                }
                revert AccessTemplate__NoAdminPrivileges();
            }
            managerSet.add(userWallet);
        }
    }

    // admin可以删除其它的admin，不能删除自己     roleType 1: 移除admin   2：移除manager
    function removeUserFromSet(
        uint8 roleType,
        address userWallet
    ) public virtual {
        require(userWallet != msg.sender, "Can't remove yourself");
        if (roleType == 1) {
            require(adminSet.contains(userWallet), "Not in adminSet");
            if (msg.sender != owner() && !adminSet.contains(msg.sender)) {
                if (debugMode) {
                    string memory msgStr = DebugConcatObj(
                        "RemoveSet1:",
                        msg.sender,
                        owner(),
                        0,
                        0
                    );
                    emit FailMsg(msgStr);
                    return;
                }
                revert AccessTemplate__NoOwnerAndAdminPrivileges();
            }
            adminSet.remove(userWallet);
            return;
        }

        if (roleType == 2) {
            require(managerSet.contains(userWallet), "Not in managerSet");
            if (msg.sender != owner() && !adminSet.contains(msg.sender)) {
                if (debugMode) {
                    emit FailMsg(
                        DebugConcatObj("RemoveSet2:", msg.sender, owner(), 0, 0)
                    );
                    return;
                }
                revert AccessTemplate__NoOwnerAndAdminPrivileges();
            }
            managerSet.remove(userWallet);
        }
    }

    function setIsContains(
        uint8 roleType,
        address userWallet
    ) public view virtual returns (bool result) {
        require(roleType == 1 || roleType == 2, "Invalid params");
        if (roleType == 1) {
            result = adminSet.contains(userWallet);
        }
        if (roleType == 2) {
            result = managerSet.contains(userWallet);
        }
    }

    function getSetCount(
        uint8 roleType
    ) public view virtual returns (uint256 len) {
        require(roleType == 1 || roleType == 2, "Invalid params");
        if (roleType == 1) {
            len = adminSet.length();
        }
        if (roleType == 2) {
            len = managerSet.length();
        }
    }

    function getAllSetAccounts(
        uint8 roleType
    ) public view virtual returns (address[] memory addressArr) {
        require(roleType == 1 || roleType == 2, "Invalid params");
        if (roleType == 1) {
            addressArr = adminSet.values();
        }
        if (roleType == 2) {
            addressArr = managerSet.values();
        }
    }

    /**
     * 查询用户是否拥有admin 和 manager的管理权限
     * @param wallet 用户钱包地址
     */
    function getUserIdentities(
        address wallet
    ) public view virtual returns (bool[] memory) {
        bool[] memory identities = new bool[](3);

        wallet == owner() ? identities[0] = true : identities[0] = false;

        identities[1] = adminSet.contains(wallet);
        identities[2] = managerSet.contains(wallet);

        return identities;
    }
}
