/* eslint-disable */
// 形态对齐真实 MusicFree 插件：require axios/cheerio/crypto-js，
// search 里抓 HTML，getMediaSource 依赖 search 写入的自定义字段。
const axios = require("axios");
const cheerio = require("cheerio");
const CryptoJS = require("crypto-js");
const storage = require("musicfree/storage");

const BASE = "__BASE__";

module.exports = {
  platform: "测试插件",
  version: "1.2.3",
  author: "probe",
  description: "OmiocLink 兼容性测试插件",
  srcUrl: BASE + "/plugin.js",
  primaryKey: ["id"],
  defaultSearchType: "music",
  supportedSearchType: ["music", "sheet"],
  userVariables: [
    { key: "token", name: "令牌", hint: "随便填" },
    { key: "", name: "没有 key 应被过滤" },
  ],

  async search(query, page, type) {
    const { data } = await axios.get(BASE + "/search", {
      params: { q: query, page: page },
    });
    const $ = cheerio.load(data.html);
    const items = [];
    $("li.song").each((_, element) => {
      const node = $(element);
      items.push({
        id: node.attr("data-id"),
        // 插件自己的字段：只有原样往返才能让 getMediaSource 取到
        hash: node.attr("data-hash"),
        title: node.find(".title").text(),
        artist: node.find(".artist").text(),
        album: "测试专辑",
        artwork: BASE + node.find("img").attr("src"),
        duration: 180,
        sign: CryptoJS.MD5(query + "salt").toString(),
      });
    });
    await storage.setItem("lastQuery", String(query));
    return { isEnd: page >= 2, data: items };
  },

  async getMediaSource(musicItem, quality) {
    if (!musicItem.hash) {
      throw new Error("musicItem 缺少插件自己的 hash 字段");
    }
    const token = env.getUserVariables().token || "";
    const { data } = await axios.post(
      BASE + "/resolve",
      JSON.stringify({ hash: musicItem.hash, quality: quality, token: token }),
      { headers: { "content-type": "application/json" } },
    );
    return {
      url: data.url,
      headers: { referer: data.referer, "user-agent": data.userAgent },
    };
  },

  async getTopLists() {
    const { data } = await axios.get(BASE + "/toplists");
    return [
      {
        title: "测试榜单分组",
        data: data.items.map((item) => ({
          id: item.id,
          title: item.title,
          coverImg: BASE + "/cover.png",
        })),
      },
    ];
  },

  async getTopListDetail(topListItem, page) {
    const { data } = await axios.get(BASE + "/toplist-detail", {
      params: { id: topListItem.id, page: page },
    });
    return {
      isEnd: page >= 2,
      topListItem: topListItem,
      musicList: data.items.map((item) => ({
        id: item.id,
        hash: item.hash,
        title: item.title,
        artist: item.artist,
      })),
    };
  },

  async getRecommendSheetTags() {
    const { data } = await axios.get(BASE + "/sheet-tags");
    return {
      pinned: data.pinned.map((item) => ({ id: item.id, title: item.title })),
      data: data.groups.map((group) => ({
        title: group.title,
        data: group.tags.map((tag) => ({ id: tag.id, title: tag.title })),
      })),
    };
  },

  async getRecommendSheetsByTag(tag, page) {
    const { data } = await axios.get(BASE + "/sheets", {
      params: { tag: tag.id, page: page || 1 },
    });
    return {
      isEnd: page >= 2,
      data: data.items.map((item) => ({
        id: item.id,
        title: item.title,
        coverImg: BASE + "/cover.png",
        artist: "歌单作者",
      })),
    };
  },

  async getMusicSheetInfo(sheetItem, page) {
    const { data } = await axios.get(BASE + "/sheet-detail", {
      params: { id: sheetItem.id, page: page },
    });
    return {
      isEnd: page >= 2,
      sheetItem: sheetItem,
      musicList: data.items.map((item) => ({
        id: item.id,
        hash: item.hash,
        title: item.title,
        artist: item.artist,
      })),
    };
  },

  async getLyric(musicItem) {
    const { data } = await axios.get(BASE + "/lyric", {
      params: { id: musicItem.id },
    });
    return { rawLrc: data.lrc, translation: data.translation };
  },

  async getMusicComments(musicItem, page) {
    const { data } = await axios.get(BASE + "/comments", {
      params: { id: musicItem.id, page: page || 1 },
    });
    return { isEnd: true, data: data.items };
  },

  async getArtistWorks(artistItem, page, type) {
    const { data } = await axios.get(BASE + "/artist", {
      params: { id: artistItem.id, page: page, type: type },
    });
    return { isEnd: true, data: data.items };
  },

  async getAlbumInfo(albumItem, page) {
    const { data } = await axios.get(BASE + "/album", {
      params: { id: albumItem.id, page: page },
    });
    return { isEnd: true, albumItem: albumItem, musicList: data.items };
  },

  async getMusicInfo(musicBase) {
    return { id: musicBase.id, title: "补全后的标题", artist: "补全后的歌手" };
  },

  async importMusicSheet(urlLike) {
    return [{ id: "imported-1", title: urlLike, artist: "导入" }];
  },

  async importMusicItem(urlLike) {
    return { id: "imported-item", title: urlLike, artist: "导入" };
  },

  async readStorage(key) {
    return await storage.getItem(key);
  },

  async broken() {
    throw new Error("插件内部故意抛错");
  },

  async slow() {
    await new Promise((resolve) => setTimeout(resolve, 3000));
    return "太晚了";
  },
};