{
  $require($subjectPolicy == {{policyId}}),
  $require($subjectVault == {{vault}}),
  $require($subjectId == {{payAId}} || $subjectId == {{payBId}}),
  $require($subjectNativeValue == 0),
  $require($subjectArgCount == 1),
  $require($subjectArg(0) > 0 && $subjectArg(0) <= {{cap}}),
  $require($write({{registryWord}}, 0x4671fe19, {$subjectPolicy, {{meterId}}, 2592000, $subjectArg(0), {{monthlyLimit}}, $subjectVault, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000000000000000000000000000}))
}
