# USB-mode screens

Three illustrations generated with Gemini on 2026-10-15 from prompts asking for a 19th-century engraving of a Kindle Paperwhite, in the spirit of the Old Book Illustrations sleep screens. Originals here (1493x2000 JPEG); [the converter](../tools/Convert-UsbScreens.ps1) produces the 758x1024 raw framebuffer dumps the plugin writes to `/dev/fb0`, with each row padded to 768 bytes.

| File | Shown when |
| :-- | :-- |
| `usb-waiting.jpg` (hourglass, cable unplugged) | KOReader has closed and the helper waits for a computer |
| `usb-active.jpg` (USB trident, cable plugged) | the storage is exported |
| `usb-returning.jpg` (return arrow) | the drive was released and the storage is being remounted |

The bottom quarter of each image is left empty on purpose: the helper prints the status text there.

`unused/` keeps alternatives that are not converted (the converter only reads this folder's top level): `usb-active-check.jpg`, a check mark, the first version of the active screen.
