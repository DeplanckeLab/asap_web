# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'shellwords'

# Prepare H5AD files for legacy Java (ASAP.jar) preparsing and parsing (release < 8).
module H5adJavaPrep
  LEGACY_JAVA_H5AD_WORK_SUFFIX = '.__preparsing_java.h5ad'

  # In-place h5py migration: obs|var/__categories/<col> + flat codes -> <col>/{categories,codes}.
  # Keeps matrix and other HDF5 layout unchanged so legacy Java H5ADHandler still works.
  H5AD_LEGACY_CATEGORIES_MIGRATE_PY = (<<~'PYTHON').freeze
    import h5py
    import numpy as np
    import sys

    def decode_cats(arr):
        out = []
        for v in arr:
            if isinstance(v, (bytes, np.bytes_)):
                out.append(v.decode("utf-8"))
            else:
                out.append(str(v))
        return np.array(out, dtype=object)

    def migrate_table(table):
        if "__categories" not in table:
            return
        cats_grp = table["__categories"]
        for col in list(cats_grp.keys()):
            if col not in table:
                continue
            col_item = table[col]
            if not isinstance(col_item, h5py.Dataset):
                continue
            codes = np.asarray(col_item[()])
            categories = decode_cats(cats_grp[col][()])
            del table[col]
            col_grp = table.create_group(col)
            col_grp.create_dataset("categories", data=categories)
            col_grp.create_dataset("codes", data=codes.astype(np.int32, copy=False))
            col_grp.attrs["encoding-type"] = "categorical"
            col_grp.attrs["encoding-version"] = "0.2.0"
        del table["__categories"]

    path = sys.argv[1]
    with h5py.File(path, "r+") as f:
        for section in ("obs", "var"):
            if section in f and isinstance(f[section], h5py.Group):
                migrate_table(f[section])
  PYTHON

  H5AD_LEGACY_CATEGORIES_DETECT_PY = (<<~'PYTHON').freeze
    import h5py, sys

    def has_legacy_categories(g):
        if "__categories" in g:
            return True
        for _name, child in g.items():
            if isinstance(child, h5py.Group) and has_legacy_categories(child):
                return True
        return False

    with h5py.File(sys.argv[1], "r") as f:
        print("yes" if has_legacy_categories(f) else "no")
  PYTHON

  H5AD_CSC_DETECT_PY = (<<~'PYTHON').freeze
    import h5py, sys

    def is_csc(g):
        if not isinstance(g, h5py.Group):
            return False
        enc = g.attrs.get("encoding-type", "")
        if isinstance(enc, bytes):
            enc = enc.decode("ascii", "replace")
        return enc == "csc_matrix"

    path = sys.argv[1]
    with h5py.File(path, "r") as f:
        if "X" in f and is_csc(f["X"]):
            print("yes")
            sys.exit(0)
        if "layers" in f:
            for n in f["layers"]:
                lg = f["layers"][n]
                if isinstance(lg, h5py.Group) and is_csc(lg):
                    print("yes")
                    sys.exit(0)
        if "raw" in f and isinstance(f["raw"], h5py.Group) and "X" in f["raw"]:
            rx = f["raw"]["X"]
            if isinstance(rx, h5py.Group) and is_csc(rx):
                print("yes")
                sys.exit(0)
    print("no")
  PYTHON

  H5AD_CSC_TO_CSR_PY = (<<~'PYTHON').freeze
    import h5py, scipy.sparse, sys
    f = h5py.File(sys.argv[1], "r+")

    def cvt(g):
        enc = g.attrs.get("encoding-type", "")
        if isinstance(enc, bytes):
            enc = enc.decode("ascii", "replace")
        if enc == "csc_matrix":
            s = tuple(g.attrs["shape"])
            m = scipy.sparse.csc_matrix((g["data"][:], g["indices"][:], g["indptr"][:]), shape=s).tocsr()
            del g["data"], g["indices"], g["indptr"]
            g.create_dataset("data", data=m.data, chunks=True)
            g.create_dataset("indices", data=m.indices, chunks=True)
            g.create_dataset("indptr", data=m.indptr, chunks=True)
            g.attrs["encoding-type"] = "csr_matrix"

    cvt(f["X"])
    if "layers" in f:
        for n in f["layers"]:
            if isinstance(f["layers"][n], h5py.Group):
                cvt(f["layers"][n])
    if "raw" in f and "X" in f["raw"]:
        rx = f["raw"]["X"]
        if isinstance(rx, h5py.Group):
            cvt(rx)
    f.close()
  PYTHON

  module_function

  def legacy_java_h5ad_work_path?(path)
    path.to_s.end_with?(LEGACY_JAVA_H5AD_WORK_SUFFIX, '.__preparsing_java_csr.h5ad')
  end

  def has_legacy_categories?(host_path, workdir:)
    docker_python_one_liner(host_path, workdir, H5AD_LEGACY_CATEGORIES_DETECT_PY) == 'yes'
  end

  def needs_csr?(host_path, workdir:)
    docker_python_one_liner(host_path, workdir, H5AD_CSC_DETECT_PY) == 'yes'
  end

  def migrate_legacy_categories!(host_path, workdir:, logger: Rails.logger)
    run_docker_python_script(
      host_path,
      workdir,
      H5AD_LEGACY_CATEGORIES_MIGRATE_PY,
      logger: logger,
      label: 'H5AD legacy __categories migration'
    )
    logger.info("[H5adJavaPrep] Migrated legacy __categories in #{host_path}")
  end

  def convert_csc_to_csr!(host_path, workdir:, logger: Rails.logger)
    run_docker_python_script(host_path, workdir, H5AD_CSC_TO_CSR_PY, logger: logger, label: 'H5AD CSC to CSR')
  end

  def prepare_work_copy!(source_path, workdir:, logger: Rails.logger)
    work = File.join(workdir.to_s, LEGACY_JAVA_H5AD_WORK_SUFFIX)
    FileUtils.rm_f(work)
    FileUtils.cp(source_path.to_s, work)

    needs_upgrade = has_legacy_categories?(work, workdir: workdir)
    needs_csr = needs_csr?(work, workdir: workdir)

    if needs_upgrade
      logger.info("[H5adJavaPrep] H5AD has legacy __categories groups; migrating for Java: #{work}")
      migrate_legacy_categories!(work, workdir: workdir, logger: logger)
      needs_csr = needs_csr?(work, workdir: workdir)
    end

    if needs_csr
      logger.info("[H5adJavaPrep] H5AD has CSC sparse matrix groups; converting for Java: #{work}")
      convert_csc_to_csr!(work, workdir: workdir, logger: logger)
    end

    work
  end

  def prepare_for_java_parse!(host_path, workdir:, logger: Rails.logger)
    path = host_path.to_s
    if has_legacy_categories?(path, workdir: workdir)
      logger.info("[H5adJavaPrep] Migrating legacy __categories before Java parse: #{path}")
      migrate_legacy_categories!(path, workdir: workdir, logger: logger)
    end
    return unless needs_csr?(path, workdir: workdir)

    logger.info("[H5adJavaPrep] Converting CSC to CSR before Java parse: #{path}")
    convert_csc_to_csr!(path, workdir: workdir, logger: logger)
  end

  def docker_python_one_liner(host_path, workdir, script)
    stdout, stderr, status = Open3.capture3(
      'docker', 'exec',
      '--user', '1006:1006',
      '--workdir', workdir.to_s,
      ENV.fetch('ASAP_RUN_CONTAINER'),
      'python3', '-c', script, host_path.to_s
    )
    unless status.success?
      Rails.logger.warn(
        "[H5adJavaPrep] detect failed (exit #{status.exitstatus}): #{stderr.to_s.strip.presence || stdout.to_s.strip}"
      )
      return 'no'
    end

    stdout.to_s.strip
  end

  def run_docker_python_script(host_path, workdir, script, logger:, label:)
    stdout, stderr, status = Open3.capture3(
      'docker', 'exec',
      '--user', '1006:1006',
      '--workdir', workdir.to_s,
      ENV.fetch('ASAP_RUN_CONTAINER'),
      'python3', '-c', script, host_path.to_s
    )
    return if status.success?

    msg = stderr.to_s.strip.presence || stdout.to_s.strip.presence || "exit #{status.exitstatus}"
    raise "#{label} failed for preparsing: #{msg}"
  end

  def run_docker_exec(workdir, inner, logger:, label:)
    docker_cmd = [
      'docker', 'exec',
      '--user', '1006:1006',
      '--workdir', workdir.to_s,
      ENV.fetch('ASAP_RUN_CONTAINER'),
      '/bin/sh', '-c', inner
    ]
    full_cmd = Shellwords.join(docker_cmd)
    logger.info("[H5adJavaPrep] #{label}: #{full_cmd}")
    stdout, stderr, status = Open3.capture3(full_cmd)
    return if status.success?

    msg = stderr.to_s.strip.presence || stdout.to_s.strip.presence || "exit #{status.exitstatus}"
    raise "#{label} failed: #{msg}"
  end
end
