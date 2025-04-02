const defaultTheme = require("tailwindcss/defaultTheme");
module.exports = {
  darkMode: "media",
  content: [
    "./public/*.html",
    "./app/helpers/**/*.rb",
    "./app/javascript/**/*.js",
    "./app/views/**/*.{erb,haml,html,slim}",
    "./app/assets/builds/*"
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ["Inter var", ...defaultTheme.fontFamily.sans],
      },
      colors: {},
      spacing: {
        "17": "4.25rem",
      },
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    require("@tailwindcss/typography"),
    require("@tailwindcss/container-queries")
  ]
}
