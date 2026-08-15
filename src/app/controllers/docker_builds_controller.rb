# frozen_string_literal: true

class DockerBuildsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_admin

  def index
    @docker_builds = DockerBuild.includes(:docker_image).order(id: :desc)
  end
end
