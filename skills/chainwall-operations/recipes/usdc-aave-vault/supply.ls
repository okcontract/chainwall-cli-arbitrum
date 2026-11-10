{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($arg0 > 0),
  $require(@token(circle/usdc).approve(0x794a61358D6845594F94dc1DB02A252b5b4814aD :: address, $arg0 :: uint256)),
  @contract(aave/pool-v3).supply(0xaf88d065e77c8cC2239327C5EDb3A432268e5831 :: address, $arg0 :: uint256, {{vault}} :: address, 0 :: uint16)
}
