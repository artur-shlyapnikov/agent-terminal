# Third-Party Notices

AgentTerminal is distributed under the MIT License; the complete text is in
[`LICENSE`](LICENSE). **No GPL-licensed code may be included in the repository
or its build products.** The license audit gate is
`Scripts/verify-third-party-licenses.sh`: it checks the tracked tree for copied
GPL notices or cmux-derived source and verifies the pinned dependencies below.
Every entry in this file carries or links to its upstream notice.

## Ghostty — MIT License

Vendored and pinned by commit (see `Vendor/Ghostty/commit.txt`); built as a
local xcframework by `Scripts/build-ghostty-xcframework.sh`.

> Copyright (c) Mitchell Hashimoto and Ghostty contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## GRDB.swift — MIT License

Swift Package dependency, pinned to latest stable 7.x in
`Packages/Package.resolved` (https://github.com/groue/GRDB.swift).

> Copyright (c) 2015-2024 Gwendal Roué, Groupe Minutillo
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## Herdr — Apache-2.0 (concepts only; no code)

AgentTerminal borrows *architectural concepts* from Herdr (semantic agents,
lifecycle authority, screen manifests, event-driven wait). **No Herdr source
code, configuration, or manifest files are copied into this repository.** Should
that ever change, Apache-2.0 requires retaining its LICENSE and NOTICE contents
here; until then no Apache notice text is reproduced.

## cmux — GPL-3.0-or-later — EXCLUDED

cmux is used strictly as an architecture reference (AppKit + libghostty
embedding patterns, architecture notes §2.4). **No cmux source code may be
copied, translated, or adapted** into this repository, because doing so would
force the entire product under GPL-3.0-or-later. The license audit must fail
the build on any detected cmux-derived code.
