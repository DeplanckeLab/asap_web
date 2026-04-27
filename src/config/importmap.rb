# Pin npm packages by running ./bin/importmap

pin "application", preload: false
pin "bootstrap", to: "bootstrap.min.js", preload: false
pin "@hotwired/turbo-rails", to: "turbo.min.js", preload: false
pin "@hotwired/stimulus", to: "stimulus.js", preload: false
pin "@rails/actioncable", to: "actioncable.esm.js"
# pin "@hotwired/stimulus-loading", to: "stimulus-loading.js", preload: true
pin "@rails/request.js", to: "https://ga.jspm.io/npm:@rails/request.js@0.0.12/src/index.js"
pin "@fortawesome/fontawesome-free", to: "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.1.1/js/all.min.js", preload: true
#pin "plotly", to: "https://cdn.plot.ly/plotly-2.32.0.min.js", preload: true
pin "@coreui/coreui", to: "https://cdn.jsdelivr.net/npm/@coreui/coreui@4.3.0/dist/js/coreui.bundle.min.js", preload: true
pin "nouislider", to: "https://ga.jspm.io/npm:nouislider@15.7.1/dist/nouislider.mjs"
pin "regl", to: "https://cdn.skypack.dev/regl@2.1.0"

pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/visualization", under: "visualization"
pin_all_from "app/javascript/lib", under: "lib"
pin_all_from "app/javascript/channels", under: "channels"


