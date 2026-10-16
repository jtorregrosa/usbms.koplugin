# USB-mode screens

Three illustrations generated with Gemini on 2026-10-15 from prompts asking for a 19th-century engraving of a Kindle Paperwhite, in the spirit of the Old Book Illustrations sleep screens. Originals here (1493x2000 JPEG); [the converter](../tools/Convert-UsbScreens.ps1) produces the 758x1024 raw framebuffer dumps the plugin writes to `/dev/fb0`, with each row padded to 768 bytes.

| File | Shown when |
| :-- | :-- |
| `usb-waiting.jpg` (hourglass, cable unplugged) | KOReader has closed and the helper waits for a computer |
| `usb-active.jpg` (USB trident, cable plugged) | the storage is exported |
| `usb-returning.jpg` (return arrow) | the drive was released and the storage is being remounted |

The bottom quarter of each image is left empty on purpose: the helper prints the status text there.

`usbms-demo.gif` is the README demo: a phone recording of the direct method on a Paperwhite 2 (FW 5.12.2.2), converted at 2x speed, 6 fps and 280 px wide:

```sh
ffmpeg -i usbms.koplugin.mp4 -an -filter_complex "[0:v]setpts=PTS/2,fps=6,scale=280:-2:flags=lanczos,hqdn3d=2:2:20:20,split[a][b];[a]palettegen=max_colors=48:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" -loop 0 usbms-demo.gif
```