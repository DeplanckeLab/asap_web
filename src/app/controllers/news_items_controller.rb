class NewsItemsController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  before_action :ensure_admin!, except: [:index, :show]
  before_action :set_news_item, only: [:show, :edit, :update, :destroy]

  def index
    @news_items = if admin?
                    NewsItem.ordered
                  else
                    NewsItem.published.ordered
                  end
  end

  def show
    unless @news_item.published? || admin?
      redirect_to news_items_path, alert: 'This news item is not available.'
    end
  end

  def new
    @news_item = NewsItem.new(
      news_type: 'announcement',
      icon: NewsItem.default_icon_for('announcement'),
      published_at: Time.current,
      published: true,
      show_on_welcome: true
    )
  end

  def edit; end

  def create
    @news_item = NewsItem.new(news_item_params)
    @news_item.user = current_user

    if @news_item.save
      redirect_to @news_item, notice: 'News item was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @news_item.update(news_item_params)
      redirect_to @news_item, notice: 'News item was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @news_item.destroy
    redirect_to news_items_path, notice: 'News item was successfully deleted.'
  end

  private

  def set_news_item
    @news_item = NewsItem.find(params[:id])
  end

  def ensure_admin!
    return if admin?

    redirect_to news_items_path, alert: 'You are not authorized to perform this action.'
  end

  def news_item_params
    params.require(:news_item).permit(
      :title,
      :body,
      :news_type,
      :icon,
      :published_at,
      :published,
      :show_on_welcome
    )
  end
end
