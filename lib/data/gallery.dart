import 'package:photo_manager/photo_manager.dart';

import 'db.dart';

/// Reads the phone's photo library, newest first, optionally limited to a
/// date range. Face scanning only looks at photos; browsing ([media]) also
/// shows videos.
class Gallery {
  static FilterOptionGroup _filter(DaySpan? dates) => FilterOptionGroup(
        imageOption: const FilterOption(
            sizeConstraint: SizeConstraint(ignoreSize: true)),
        videoOption: const FilterOption(
            sizeConstraint: SizeConstraint(ignoreSize: true)),
        createTimeCond: dates == null
            ? DateTimeCond(min: DateTime(1970), max: DateTime(2100))
            : DateTimeCond(min: dates.start, max: dates.end),
        orders: const [OrderOption(type: OrderOptionType.createDate)],
      );

  static RequestType _type(bool media) => media ? RequestType.common : RequestType.image;

  /// Asks for photo access, including where photos were taken (for the
  /// Places map); false if the user said no.
  static Future<bool> requestAccess() async => (await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: true),
        ),
      ))
          .hasAccess;

  static Future<List<AssetPathEntity>> albums({DaySpan? dates, bool media = false}) =>
      PhotoManager.getAssetPathList(
          type: _type(media), filterOption: _filter(dates));

  /// "All photos", or null when the library is empty.
  static Future<AssetPathEntity?> allPhotos({DaySpan? dates, bool media = false}) async {
    final paths = await PhotoManager.getAssetPathList(
        type: _type(media), onlyAll: true, filterOption: _filter(dates));
    return paths.isEmpty ? null : paths.first;
  }

  /// Every video, or null when there are none.
  static Future<AssetPathEntity?> videos({DaySpan? dates}) async {
    final paths = await PhotoManager.getAssetPathList(
        type: RequestType.video, onlyAll: true, filterOption: _filter(dates));
    return paths.isEmpty ? null : paths.first;
  }

  /// Photos and videos marked as favourite (Android 11+ keeps the flag).
  static Future<AssetPathEntity?> favourites() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: CustomFilter.sql(
        where: '${CustomColumns.android.isFavorite} = 1',
        orderBy: [OrderByItem.desc(CustomColumns.base.createDate)],
      ),
    );
    return paths.isEmpty ? null : paths.first;
  }

  /// A phone album by its id, or null if it no longer exists.
  static Future<AssetPathEntity?> albumById(String id, {bool media = false}) async {
    try {
      return await AssetPathEntity.obtainPathFromProperties(
        id: id,
        type: _type(media),
        optionGroup: _filter(null),
        maxDateTimeToNow: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// The same album, but only containing items within [dates].
  static Future<AssetPathEntity> inRange(
          AssetPathEntity album, DaySpan? dates, {bool media = false}) =>
      AssetPathEntity.obtainPathFromProperties(
        id: album.id,
        albumType: album.albumType,
        type: _type(media),
        optionGroup: _filter(dates),
        maxDateTimeToNow: false,
      );
}
