{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 0),
  if(@token(aave/ausdc).balanceOf({{vault}} :: address) == 0, $noop, @contract(aave/pool-v3).withdraw({{usdc}} :: address, 115792089237316195423570985008687907853269984665640564039457584007913129639935 :: uint256, {{vault}} :: address)),
  $require(@token(circle/usdc).transfer({{cold}} :: address, @token(circle/usdc).balanceOf({{vault}} :: address) :: uint256))
}
