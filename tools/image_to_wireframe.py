"""
image_to_wireframe.py -- turns a photo into a wireframe-style line-art image.

This is 2D edge/contour extraction (Sobel gradient magnitude + threshold),
NOT 3D reconstruction. It cannot recover depth or geometry from a single
photo -- that needs a trained neural network (what commercial "photo to 3D
model" services actually do), not a from-scratch script. What this DOES
give you: a real, useful modeling-reference image -- clean white contour
lines on black, the same visual language as the reference wireframe sheet
you showed earlier -- that you (or a Blender background-image workflow)
can trace over when hand-modeling something to match a photo.

Usage:
  python tools/image_to_wireframe.py <input_image> [output_image] [--thickness N]

Requires only PIL + numpy (both already available -- no extra installs).
"""
import sys
import numpy as np
from PIL import Image, ImageFilter


def to_wireframe(input_path: str, output_path: str, line_thickness: int = 1) -> None:
	orig = Image.open(input_path)
	# TRANSPARENT-BACKGROUND SUPPORT (2026-07-19): "can I have the vertices
	# only be on the deer" -- color-based background suppression (greenness
	# masking) can't cleanly separate a subject from same-colored background
	# (a brown deer over brown dirt, see the earlier test). A real alpha
	# channel has NO such ambiguity -- alpha=0 IS background, by
	# construction, not by inference. If the source image carries one (e.g.
	# from a background-removal tool), zero out the gradient everywhere
	# outside it, guaranteeing every kept edge belongs to the subject.
	alpha_mask = None
	if orig.mode in ("RGBA", "LA") or "transparency" in orig.info:
		alpha = np.asarray(orig.convert("RGBA").split()[-1], dtype=np.float32)
		alpha_mask = alpha > 128

	img = orig.convert("L")  # grayscale
	# a slight blur first -- real photos are noisy; edge detection on raw
	# pixel noise produces a fuzz of tiny false edges instead of clean lines
	img = img.filter(ImageFilter.GaussianBlur(radius=1.2))
	arr = np.asarray(img, dtype=np.float32)

	# Sobel gradients -- the standard, simple edge-detection kernel pair
	sobel_x = np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]], dtype=np.float32)
	sobel_y = np.array([[-1, -2, -1], [0, 0, 0], [1, 2, 1]], dtype=np.float32)

	def convolve(a: np.ndarray, k: np.ndarray) -> np.ndarray:
		# manual same-padding 2D convolution -- no scipy dependency
		kh, kw = k.shape
		pad_h, pad_w = kh // 2, kw // 2
		padded = np.pad(a, ((pad_h, pad_h), (pad_w, pad_w)), mode="edge")
		out = np.zeros_like(a)
		for i in range(kh):
			for j in range(kw):
				out += k[i, j] * padded[i:i + a.shape[0], j:j + a.shape[1]]
		return out

	gx = convolve(arr, sobel_x)
	gy = convolve(arr, sobel_y)
	magnitude = np.sqrt(gx ** 2 + gy ** 2)
	if alpha_mask is not None:
		magnitude = magnitude * alpha_mask
	magnitude = (magnitude / (magnitude.max() + 1e-6)) * 255.0

	# HYSTERESIS (2026-07-19): the same noise-rejection idea as the Arduino
	# sensor grid's bridge.py -- "switch only on a real margin, not a
	# noise-level blip" -- applied here as two thresholds instead of one.
	# A single flat threshold treated a strong deer-outline edge and a weak
	# isolated blade-of-grass edge as equally "real" the moment either
	# crossed it, which is why a busy natural photo came out as background
	# noise drowning the subject. Now: pixels above the HIGH bar are kept
	# outright (strong edges); pixels above the LOW bar are kept ONLY if
	# they're 8-connected to a strong edge (part of a real contour); anything
	# else -- an edge with no strong neighbor, i.e. actual noise -- is
	# dropped, same as the sensor code discarding a blip with no real margin
	# behind it.
	high = np.percentile(magnitude, 92)
	low = np.percentile(magnitude, 75)
	strong = magnitude >= high
	weak = (magnitude >= low) & ~strong

	kept = strong.copy()
	frontier = strong.copy()
	# flood-fill weak pixels outward from strong ones, one ring at a time,
	# until nothing new gets pulled in -- a small, dependency-free stand-in
	# for Canny's connected-component hysteresis pass.
	for _ in range(6):
		grown = np.zeros_like(frontier)
		grown[1:, :]  |= frontier[:-1, :]
		grown[:-1, :] |= frontier[1:, :]
		grown[:, 1:]  |= frontier[:, :-1]
		grown[:, :-1] |= frontier[:, 1:]
		grown[1:, 1:]   |= frontier[:-1, :-1]
		grown[:-1, :-1] |= frontier[1:, 1:]
		grown[1:, :-1]  |= frontier[:-1, 1:]
		grown[:-1, 1:]  |= frontier[1:, :-1]
		newly_kept = grown & weak & ~kept
		if not newly_kept.any():
			break
		kept |= newly_kept
		frontier = newly_kept

	lines = kept.astype(np.uint8) * 255

	if line_thickness > 1:
		lines_img = Image.fromarray(lines).filter(
			ImageFilter.MaxFilter(size=line_thickness * 2 + 1))
		lines = np.asarray(lines_img)

	# white lines on black, matching the reference wireframe sheet's own look
	out = Image.fromarray(lines, mode="L").convert("RGB")
	out.save(output_path)
	print(f"[image_to_wireframe] wrote {output_path} ({out.size[0]}x{out.size[1]})")


if __name__ == "__main__":
	if len(sys.argv) < 2:
		print(__doc__)
		sys.exit(1)
	in_path = sys.argv[1]
	out_path = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else \
		in_path.rsplit(".", 1)[0] + "_wireframe.png"
	thickness = 1
	if "--thickness" in sys.argv:
		thickness = int(sys.argv[sys.argv.index("--thickness") + 1])
	to_wireframe(in_path, out_path, thickness)
