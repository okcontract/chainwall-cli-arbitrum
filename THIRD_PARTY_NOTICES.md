# Third-party notices

The BUSL-1.1 license applies to the Chainwall work. Third-party components retain
their own licenses. License copies below accompany both source and binary distributions.

## Native binaries

- zqlite at commit `865223b734a5113f731ab1eb1d7d81c8ac252913`: MIT. See
  [license](LICENSES/zqlite-MIT.txt). The build also installs the fetched notice.
- SQLite is bundled by zqlite and is in the public domain. See
  <https://www.sqlite.org/copyright.html>.

## Contract artifacts

The reference JSON contains compiler artifacts and bytecode, including dependencies
of the Chainwall contracts. Dependency license copies are included in `LICENSES/`:

- OpenZeppelin Contracts: MIT, at revision
  [`54a8027afb25ccebcd602ba76494b2c7d4d9f9ed`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/54a8027afb25ccebcd602ba76494b2c7d4d9f9ed).
- Safe contracts: LGPL-3.0, at revision
  [`dc437e8fba8b4805d76bcbd1c668c9fd3d1e83be`](https://github.com/safe-global/safe-contracts/tree/dc437e8fba8b4805d76bcbd1c668c9fd3d1e83be).

The GPLv3 text incorporated by LGPLv3, and referenced as the Change License, is
included in `LICENSES/GPL-3.0-only.txt`.

Foundry and Zig are separately installed tools and are not distributed here.
