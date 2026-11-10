{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 2),
  $require($arg0 > 0),
  $require($arg1 > 0),
  $require(@token(weth/weth).approve({{router}} :: address, $arg0 :: uint256)),
  @contract(uniswap/swap-router-02).exactInputSingle{value: 0}({{{weth}} :: address, {{usdc}} :: address, 500 :: uint24, {{vault}} :: address, $arg0 :: uint256, $arg1 :: uint256, 0 :: uint160})
}
