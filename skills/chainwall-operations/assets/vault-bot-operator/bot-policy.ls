{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectId == {{supplyId}} || $subjectId == {{withdrawId}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($subjectArg(0) > 0 && $subjectArg(0) <= 100000000),
  $require($write({{registryWord}}, 0x4671fe19, {$subjectPolicy, {{meterId}}, 86400, $subjectArg(0), {{dailyLimit}}, $subjectVault, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000000000000000000000000000}))
}
