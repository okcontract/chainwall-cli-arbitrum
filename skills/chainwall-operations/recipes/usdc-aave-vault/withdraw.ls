{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($arg0 > 0),
  @contract(aave/pool-v3).withdraw(0xaf88d065e77c8cC2239327C5EDb3A432268e5831 :: address, $arg0 :: uint256, {{vault}} :: address)
}
