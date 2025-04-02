//const defaultTheme = require('tailwindcss/defaultTheme')

module.exports = {
  content: [
//    "./src/app/assets/stylesheets/application.tailwind.css",
    './public/*.html',
    './app/helpers/**/*.rb',
    './app/javascript/**/*.js',
    './app/views/**/*.{erb,haml,html,slim}',
     './config/**/*.rb'
//    './app/assets/builds/*'
  ],
  theme: {
    extend: {
      fontFamily: {
  //      sans: ['Inter var', ...defaultTheme.fontFamily.sans],
      },
      colors: {
      },
    },
  },
  plugins: [
  //  require('@tailwindcss/forms'),
  //  require('@tailwindcss/typography'),
  //  require('@tailwindcss/container-queries'),
  ]
} 