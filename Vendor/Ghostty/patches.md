# Local patches to libghostty

Status: **none**. The vendored library is built unmodified from the commit
pinned in `commit.txt`.

If a local patch ever becomes necessary, add one entry per patch here using
the template below and keep the corresponding `.patch` file next to this
document. `Scripts/build-ghostty-xcframework.sh` must then be extended to
apply patches after `git checkout` of the pin (e.g.
`git apply "$VENDOR_DIR/0001-*.patch"`) — update the script in the same
change so builds stay reproducible.

## Template

### 0001-<short-name>.patch
- **Against pin:** `<sha from commit.txt>`
- **Reason:** why upstream cannot be used unmodified (link to issue if any)
- **Upstream status:** none / PR filed at <url> / rejected / merged in <sha>
- **Removal condition:** what lets us drop this patch (upstream fix, redesign)
