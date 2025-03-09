module TailwindHelper

  def tw_btn(type = :primary)
    h = {
      primary: "btn btn-primary",
      secondary: "btn btn-secondary",
      success: "btn btn-success",
      warning: "btn btn-warning",
      danger: "btn btn-danger",
      info: "btn btn-info",
      light: "btn btn-light",
      dark: "btn btn-dark"
    }
    
    return h[type]
  end

  def tw_menu_item(type = :default)
    h = {
      default: "menu-item menu-item-default",
      dropdown_item: "menu-item menu-item-dropdown"
    }
    
    return h[type]
  end
end
