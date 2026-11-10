{
  $require($subjectPolicy == {{minterPolicyId}}),
  $require($subjectVault == {{issuerAccount}}),
  $require($subjectId == {{mintId}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 2),
  $require($subjectArg(0) != 0),
  $require($subjectArg(1) > 0 && $subjectArg(1) <= {{mintCap}}),
  $require($write({{registryWord}}, 0x4671fe19, {$subjectPolicy, {{meterId}}, 86400, $subjectArg(1), {{dailyMintLimit}}, $subjectVault, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000000000000000000000000000}))
}
