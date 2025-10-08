class HomeController < ApplicationController
  skip_before_action :authenticate_user!

  def welcome
  end


  def file_format
    @h_formats = FileFormat.all.index_by(&:name)
    # This uses ActiveRecord's index_by method which is more efficient
    # than manually mapping and creating a hash
  end

  def tutorial
    
    @h_tutos = {
      'getting_started' => "Tutorial 1 : Getting started - Welcome to ASAP!",
      'full_pipeline' => "Tutorial 2 : Full pipeline on a project imported from the Human Cell Atlas",
      'cell_ranger' => "Tutorial 3 : How to import data from 10x [from CellRanger output]",
      'loom' => "Tutorial 4 : How to work with Loom files created by ASAP",
      'out_of_ram' => "Tutorial 5 : How to best select methods for avoiding out-of-RAM errors",
      'fca' => "Tutorial 6: How to use the visualization tools for interacting with the UMAP/t-SNE plots. An example using the Fly Cell Atlas"
      #,                                                                                                                                                                                                                        
      #      'importing_data' => "Importing data",                                                                                                                                                                              
      #      'project_details' => "Editing project details",                                                                                                                                                                    
      #      'public_projects' => "How to make your project public"                                                                                                                                                             
    }
    @h_icons = {
      'full_pipeline' => ['hca_logo.jpg', 'https://www.humancellatlas.org/'],
      'fca' => ['fca_logo.png', 'https://flycellatlas.org']
    }
    if params[:t]
      render "tutorial"
    else
      render "tutorial_list"
    end

  end 
  
end
