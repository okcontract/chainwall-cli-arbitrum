{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($arg0 > 0),
  $require(@token(circle/usdc).approve({{pool}} :: address, $arg0 :: uint256)),
  @contract(aave/pool-v3).supply({{usdc}} :: address, $arg0 :: uint256, {{vault}} :: address, 0 :: uint16)
}
