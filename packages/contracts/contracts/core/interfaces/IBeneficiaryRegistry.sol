// SPDX-License-Identifier: MIT

// Docgen-SOLC: 0.8.0
pragma solidity ^0.8.0;

interface IBeneficiaryRegistry {
  function beneficiaryExists(address _address) external view returns (bool);

  function addBeneficiary(
    address _address,
    bytes32 region,
    bytes calldata applicationCid
  ) external;

  function revokeBeneficiary(address _address) external;
}
