require 'open3'
require 'json'

# Reads Visium/spatial assets stored in a parsed Loom file and exposes them to
# the visualization layer:
#   - metadata_info: library id, tissue image dimensions and Visium scalefactors
#     (read from /attrs/spatial/<library>/... via h5py in the run container)
#   - export_hires_png: writes the hires tissue image to a PNG next to the loom
#     file so it can be streamed to the browser as the tissue background.
#
# HDF5 layout produced by the ASAP parser for a Visium H5AD:
#   /attrs/spatial/is_single
#   /attrs/spatial/<library>/images/hires   (H, W, 3) uint8
#   /attrs/spatial/<library>/scalefactors/spot_diameter_fullres
#   /attrs/spatial/<library>/scalefactors/tissue_hires_scalef
#   /col_attrs/spatial                       (n_spots, 2) fullres pixel coordinates
class SpatialDataService
  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER').freeze

  METADATA_INFO_PY = <<~PYTHON
    import json
    import sys

    import h5py

    def scalar(group, key):
        if key not in group:
            return None
        try:
            return float(group[key][()])
        except Exception:
            return None

    def main():
        loom = sys.argv[1]
        out = {'has_spatial': False, 'has_image': False, 'libraries': []}
        with h5py.File(loom, 'r') as f:
            if '/attrs/spatial' not in f:
                print(json.dumps(out))
                return 0
            spatial = f['/attrs/spatial']
            out['has_spatial'] = True
            if 'is_single' in spatial:
                try:
                    out['is_single'] = bool(spatial['is_single'][()])
                except Exception:
                    out['is_single'] = None
            libraries = [k for k in spatial.keys() if k != 'is_single']
            out['libraries'] = libraries
            if not libraries:
                print(json.dumps(out))
                return 0
            library = libraries[0]
            out['library'] = library
            base = spatial[library]
            images = base['images'] if 'images' in base else None
            if images is not None and 'hires' in images:
                shape = images['hires'].shape
                if len(shape) >= 2:
                    out['hires_height'] = int(shape[0])
                    out['hires_width'] = int(shape[1])
                    out['has_image'] = True
            scalefactors = base['scalefactors'] if 'scalefactors' in base else None
            if scalefactors is not None:
                out['tissue_hires_scalef'] = scalar(scalefactors, 'tissue_hires_scalef')
                out['spot_diameter_fullres'] = scalar(scalefactors, 'spot_diameter_fullres')
        print(json.dumps(out))
        return 0

    if __name__ == '__main__':
        sys.exit(main() or 0)
  PYTHON

  EXPORT_PNG_PY = <<~PYTHON
    import sys

    import h5py
    import numpy as np
    from PIL import Image

    def main():
        loom = sys.argv[1]
        library = sys.argv[2]
        out_path = sys.argv[3]
        dataset = '/attrs/spatial/%s/images/hires' % library
        with h5py.File(loom, 'r') as f:
            if dataset not in f:
                sys.stderr.write('dataset not found: %s' % dataset)
                return 2
            arr = np.asarray(f[dataset][:])
        if arr.dtype != np.uint8:
            arr = arr.astype(np.float64)
            max_val = arr.max()
            if max_val <= 1.0:
                arr = arr * 255.0
            arr = np.clip(arr, 0, 255).astype(np.uint8)
        if arr.ndim == 2:
            mode = 'L'
        elif arr.ndim == 3 and arr.shape[2] == 3:
            mode = 'RGB'
        elif arr.ndim == 3 and arr.shape[2] == 4:
            mode = 'RGBA'
        else:
            sys.stderr.write('unsupported image shape: %s' % str(arr.shape))
            return 3
        Image.fromarray(arr, mode=mode).save(out_path)
        return 0

    if __name__ == '__main__':
        sys.exit(main() or 0)
  PYTHON

  # Returns a hash describing the spatial assets in the loom file. Keys use
  # string names to match the JSON serialization sent to the browser.
  def self.metadata_info(loom_path)
    stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
      loom_path.to_s,
      stdin_data: METADATA_INFO_PY
    )
    unless status.success?
      Rails.logger.error("[SpatialDataService.metadata_info] failed: #{stderr}")
      return { 'has_spatial' => false, 'has_image' => false }
    end
    JSON.parse(stdout.to_s.strip)
  rescue JSON::ParserError => e
    Rails.logger.error("[SpatialDataService.metadata_info] parse error: #{e.message} - #{stdout}")
    { 'has_spatial' => false, 'has_image' => false }
  end

  def self.sanitize_library(library)
    library.to_s.gsub(/[^0-9A-Za-z_\-]/, '_')
  end

  def self.hires_cache_path(loom_path, library)
    dir = File.dirname(loom_path.to_s)
    File.join(dir, "spatial_hires_#{sanitize_library(library)}.png")
  end

  # Writes the hires tissue image to a PNG next to the loom (cached) and returns
  # its path, or nil when the image cannot be produced.
  def self.export_hires_png(loom_path, library)
    cache_path = hires_cache_path(loom_path, library)
    return cache_path if File.exist?(cache_path) && File.size(cache_path).positive?

    _stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
      loom_path.to_s, library.to_s, cache_path.to_s,
      stdin_data: EXPORT_PNG_PY
    )
    unless status.success?
      Rails.logger.error("[SpatialDataService.export_hires_png] failed: #{stderr}")
      return nil
    end
    File.exist?(cache_path) ? cache_path : nil
  end
end
