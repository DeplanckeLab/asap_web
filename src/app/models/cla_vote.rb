class ClaVote < ApplicationRecord
  belongs_to :cla
  belongs_to :cla_source, optional: true
  belongs_to :user, optional: true
  belongs_to :orcid_user, optional: true
end
