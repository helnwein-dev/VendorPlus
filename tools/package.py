from pathlib import Path
import re
import zipfile

root = Path(__file__).resolve().parents[1]
toc = root / "VendorPlus.toc"
version = re.search(r"^## Version: (.+)$", toc.read_text(), re.MULTILINE).group(1).strip()
files = [toc, root / "Icon.tga", *sorted(root.glob("*.lua"))]
output = root / "dist" / f"VendorPlus-{version}.zip"
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in files:
        info = zipfile.ZipInfo("VendorPlus/" + path.name)
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
print(output)
