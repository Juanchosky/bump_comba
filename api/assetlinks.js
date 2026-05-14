export default function handler(req, res) {
  const assetlinks = [
    {
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: "com.juanchosky.bumpcomba",
        sha256_cert_fingerprints: [
          "A9:5C:74:B8:31:5B:51:BD:89:E6:98:10:60:CA:E1:A5:33:37:23:9E:DD:29:0A:13:5B:41:A8:40:87:86:72:A9",
        ],
      },
    },
  ];

  res.setHeader("Content-Type", "application/json");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.status(200).json(assetlinks);
}
