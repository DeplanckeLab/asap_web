require 'test_helper'

class AnnotCategoricalNumericCoercibleTest < ActiveSupport::TestCase
  setup do
    @user = register_for_test_cleanup(
      User.create!(email: "annot_coercible_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Coercible annot',
      key: "coa#{SecureRandom.hex(3)}",
      user_id: @user.id
    )
    @discrete_id = DataType.find_by(name: 'DISCRETE')&.id || 3
  end

  def build_annot(categories)
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        filepath: 'parsing/output.loom',
        name: "/col_attrs/test_#{SecureRandom.hex(3)}",
        dim: 1,
        nber_cols: 10,
        latest_version: true,
        version_nber: 1,
        data_type_id: @discrete_id,
        categories_json: categories.to_json
      )
    )
  end

  test 'finite numeric category names are coercible' do
    annot = build_annot('0' => 4, '1' => 6)
    assert annot.categorical_numeric_coercible?
  end

  test 'NaN category names are coercible with finite numbers' do
    annot = build_annot('0' => 4, 'nan' => 2, '1' => 4)
    assert annot.categorical_numeric_coercible?
  end

  test 'Inf category names are not coercible' do
    annot = build_annot('0' => 4, 'Inf' => 1)
    refute annot.categorical_numeric_coercible?
  end

  test 'non-numeric category names are not coercible' do
    annot = build_annot('low' => 4, 'high' => 6)
    refute annot.categorical_numeric_coercible?
  end
end
