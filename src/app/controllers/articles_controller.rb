class ArticlesController < ApplicationController
  before_action :set_article, only: [:show, :summary]

  # GET /articles/1
  def show
    respond_to do |format|
      format.html
      format.json { render json: @article }
    end
  end

  # GET /articles/1/summary
  def summary
    respond_to do |format|
      format.html { render layout: false }
      format.json { render json: @article }
    end
  end

  private

  def set_article
    @article = Article.find(params[:id])
  end
end


