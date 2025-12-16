class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Associations
  has_many :projects, dependent: :destroy
  has_many :runs, dependent: :destroy
  has_many :annots, dependent: :destroy
  has_many :shares, dependent: :destroy

  # Validations
  validates :email, presence: true, uniqueness: true
  validates :displayed_name, presence: true, allow_blank: true

  # Callbacks
  before_save :ensure_displayed_name
  after_create :create_slurm_account

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



