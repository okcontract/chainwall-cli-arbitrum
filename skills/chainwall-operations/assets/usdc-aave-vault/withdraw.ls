{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($arg0 > 0),
  @contract(aave/pool-v3).withdraw({{usdc}} :: address, $arg0 :: uint256, {{vault}} :: address)
}
