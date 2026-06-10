# frozen_string_literal: true

class RenameEnsemblVersionToReleaseOnAssembliesAndGenes < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:assemblies, :first_ensembl_version)
      rename_column :assemblies, :first_ensembl_version, :first_ensembl_release
    end
    if column_exists?(:assemblies, :latest_ensembl_version)
      rename_column :assemblies, :latest_ensembl_version, :latest_ensembl_release
    end
    if column_exists?(:genes, :first_ensembl_version)
      rename_column :genes, :first_ensembl_version, :first_ensembl_release
    end
  end

  def down
    if column_exists?(:assemblies, :first_ensembl_release)
      rename_column :assemblies, :first_ensembl_release, :first_ensembl_version
    end
    if column_exists?(:assemblies, :latest_ensembl_release)
      rename_column :assemblies, :latest_ensembl_release, :latest_ensembl_version
    end
    if column_exists?(:genes, :first_ensembl_release)
      rename_column :genes, :first_ensembl_release, :first_ensembl_version
    end
  end
end
