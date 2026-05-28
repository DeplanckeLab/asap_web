# frozen_string_literal: true

require_relative "../seurat_tsne_umap_v8_std_methods"

namespace :reference_data do
  desc "Update v8 Seurat t-SNE (348) and UMAP (349) StdMethods for tsne.v8.R / umap.v8.R"
  task seurat_tsne_umap_v8_std_methods: :environment do
    summary = SeuratTsneUmapV8StdMethods.upsert!

    puts "Seurat t-SNE / UMAP std_methods:"
    puts "  updated:   #{summary[:updated].join(', ').presence || '(none)'}"
    puts "  unchanged: #{summary[:unchanged].join(', ').presence || '(none)'}"
  end
end
