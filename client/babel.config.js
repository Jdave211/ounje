module.exports = function (api) {
  api.cache(true);
  return {
    presets: ["babel-preset-expo"],
    plugins: [
      [
        "module:react-native-dotenv",
        {
          path: ".env",
        },
      ],
      [
        "module-resolver",
        {
          root: ["./"],
          // extensions: [".js", ".jsx", ".ts", ".tsx", ".json", ".png"],
          alias: {
            "@components": "./components",
            "@screens": "./screens",
            "@stores": "./stores",
            "@utils": "./utils",
            "@services": "./services",
            "@assets": "./assets",
            "@constants": "./constants",
            "@icons": "./icons",
          },
        },
      ],
    ],
  };
};
