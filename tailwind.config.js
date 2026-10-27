/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./app/views/belay/**/*.erb",
    "./app/views/layouts/belay/**/*.erb",
    "./app/helpers/belay/**/*.rb"
  ],
  theme: {
    extend: {}
  },
  plugins: []
};
