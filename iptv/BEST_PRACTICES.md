# أفضل الممارسات لتطبيق IPTV بآلاف القنوات

1. **القوائم**: استخدم دائماً `ListView.builder` / `GridView.builder` (لا تستخدم `children:`). أضف تحميلاً مجزّأً (60 عنصراً لكل دفعة) كما في `ChannelGrid`.
2. **التحليل الثقيل خارج الـ UI Thread**: M3U أو XMLTV الكبير → `compute(parseM3u, body)` أو `Isolate.run`.
3. **الشعارات**: `CachedNetworkImage` مع `memCacheWidth` (300 بكسل) و`maxNrOfCacheObjects` عبر `CacheManager` مخصص؛ لا تحمّل الصور بحجمها الكامل.
4. **الذاكرة**: أنشئ `Player` واحداً لكل شاشة، وفي `dispose()` ألغِ كل الـ subscriptions ثم `player.dispose()`؛ لا تُبقِ مشغلين اثنين مفتوحين أثناء التنقل بين قناتين (غيّر المصدر بـ `player.open` على نفس الـ Player للتبديل السريع).
5. **التخزين**: Hive للقنوات المخزنة مؤقتاً (TTL = 6 ساعات) مع زر "تحديث" لتجاوز الكاش.
6. **البحث**: فهرس محلي (Map حسب المجموعة) + debounce 300ms للبحث.
7. **const و RepaintBoundary** على البطاقات، و`ValueListenableBuilder`/`Selector` بدل إعادة بناء الشاشة كلها.
8. **الشبكة**: `Connection: keep-alive`، مهلة (timeout) وإعادة محاولة تصاعدية، وتحقق من الاتصال قبل فتح البث.
9. **Android TV**: أضف في `AndroidManifest.xml`: `<category android:name="android.intent.category.LEANBACK_LAUNCHER"/>` و`<uses-feature android:name="android.software.leanback" android:required="false"/>` و`<uses-feature android:name="android.hardware.touchscreen" android:required="false"/>` وأيقونة banner بحجم 320×180.
10. **RTSP**: يتطلب `rtsp-transport=tcp` (مضمّن في الكود) لتجنّب فقدان الحزم.
