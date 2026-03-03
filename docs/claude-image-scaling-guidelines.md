# Image Scaling Guidelines — iOS Camera → Claude API

## Context
iOS cameras produce 12–48MP images (3024×4032 and up). Claude's vision model internally downscales images before processing, so sending full-resolution photos wastes bandwidth and inflates token cost with zero quality benefit.

## Claude's Internal Image Limits
- Long edge is capped at **1568px** server-side before processing
- Token cost scales with pixel area: roughly `(width × height) / 750` tokens
- Hard limits: max **5MB** per image, max **20MB** total per request

## Recommended Scaling Strategy

**General content (scene, object recognition):**
- Max long edge: **1024px**
- JPEG quality: **85**
- ~3–6x token savings over 4032px originals

**OCR / document / text-heavy images:**
- Max long edge: **1568px** (match Claude's processing cap exactly — no benefit going higher)
- JPEG quality: **90**
- Preserves fine text strokes at the resolution Claude actually uses

**Never go below** ~800px on the long edge for text content — stroke detail degrades and OCR accuracy drops.

## iOS Implementation Notes
- Use `UIGraphicsImageRenderer` for resizing (modern UIKit API, iOS 10+)
- Resize *before* JPEG encoding — resize a compressed JPEG and you double-compress artifacts
- `UIImage.jpegData(compressionQuality: 0.85)` after resizing is the standard approach
- For `CMSampleBuffer` from live capture, convert to `UIImage` first, then resize, then encode

## Quick Formula
```swift
let maxLongEdge: CGFloat = isTextContent ? 1568 : 1024
let scale = maxLongEdge / max(image.size.width, image.size.height)
let targetSize = scale < 1.0
    ? CGSize(width: image.size.width * scale, height: image.size.height * scale)
    : image.size  // already small enough, don't upscale
```

## Token Cost Comparison (approximate)
| Resolution | Tokens |
|---|---|
| 4032×3024 (12MP original) | ~16,000 |
| 1568×1176 (OCR target) | ~2,500 |
| 1024×768 (general target) | ~1,050 |
