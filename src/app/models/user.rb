class User < ApplicationRecord
  # Shared sandbox owner for anonymous (guest) sessions. Do not show this
  # account's real email / displayed_name in user-facing UI — use #public_display_name.
  GUEST_SANDBOX_USER_ID = 1

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Associations
  has_many :projects, dependent: :destroy
  has_many :runs, dependent: :destroy
  has_many :annots, dependent: :destroy
  has_many :shares, dependent: :destroy
  has_many :checkpoints, dependent: :destroy
  has_many :ratings, dependent: :destroy
  has_many :news_items, dependent: :nullify
  has_many :standalone_compliance_checks, dependent: :nullify
  has_and_belongs_to_many :ips
  belongs_to :orcid_user, optional: true

  # Validations
  validates :email, presence: true, uniqueness: true
  validates :displayed_name, presence: true, allow_blank: true

  # Callbacks
  before_save :ensure_displayed_name
  after_create :create_slurm_account

  def guest_account?
    id == GUEST_SANDBOX_USER_ID
  end

  # Label for views / JSON payloads. Masks the guest sandbox account as "guest".
  def public_display_name(viewer: nil)
    return 'me' if viewer && id == viewer.id
    return 'guest' if guest_account?

    displayed_name.to_s.presence || email.to_s.split('@').first.presence || '-'
  end

  private

  def ensure_displayed_name
    self.displayed_name = email.split('@').first if displayed_name.blank?
  end
  
  def create_slurm_account
    # Create SLURM account for the new user
    # Using perform_now since background job processor may not be running
    # This is fast enough to run synchronously
    SlurmAccountCreateJob.perform_now(self.id)
  end
end



