import 'dart:convert';
import 'dart:typed_data' show Uint8List;
import 'package:hex/hex.dart';
import 'package:image/image.dart';
import 'package:gbk_codec/gbk_codec.dart';
import '../flutter_esc_pos_utils.dart';
import 'commands.dart';

class Generator {
  Generator(this._paperSize, this._profile,
      {this.spaceBetweenRows = 5, this.codec = latin1});

  // Ticket config
  final PaperSize _paperSize;
  final CapabilityProfile _profile;
  int? _maxCharsPerLine;
  // Global styles
  String? _codeTable;
  PosFontType? _font;
  // Current styles
  PosStyles _styles = const PosStyles();
  final Codec codec;
  int spaceBetweenRows;

  // ************************ Internal helpers ************************
  int _getMaxCharsPerLine(PosFontType? font) {
    if (_paperSize == PaperSize.mm58) {
      return (font == null || font == PosFontType.fontA) ? 32 : 42;
    } else if (_paperSize == PaperSize.mm72) {
      return (font == null || font == PosFontType.fontA) ? 42 : 56;
    } else {
      return (font == null || font == PosFontType.fontA) ? 48 : 64;
    }
  }

  // charWidth = default width * text size multiplier
  double _getCharWidth(PosStyles styles, {int? maxCharsPerLine}) {
    int charsPerLine = _getCharsPerLine(styles, maxCharsPerLine);
    double charWidth = (_paperSize.width / charsPerLine) * styles.width.value;
    return charWidth;
  }

  double _colIndToPosition(int colInd) {
    final int width = _paperSize.width;
    return colInd == 0 ? 0 : (width * colInd / 12 - 1);
  }

  int _getCharsPerLine(PosStyles styles, int? maxCharsPerLine) {
    int charsPerLine;
    if (maxCharsPerLine != null) {
      charsPerLine = maxCharsPerLine;
    } else {
      if (styles.fontType != null) {
        charsPerLine = _getMaxCharsPerLine(styles.fontType);
      } else {
        charsPerLine =
            _maxCharsPerLine ?? _getMaxCharsPerLine(_styles.fontType);
      }
    }
    return charsPerLine;
  }

  Uint8List _encode(String text, {bool isKanji = false}) {
    // replace some non-ascii characters
    text = text
        .replaceAll("’", "'")
        .replaceAll("´", "'")
        .replaceAll("»", '"')
        .replaceAll(" ", ' ')
        .replaceAll("•", '.');
    if (!isKanji) {
      return codec.encode(text);
    } else {
      return Uint8List.fromList(gbk_bytes.encode(text));
    }
  }

  List _getLexemes(String text) {
    final List<String> lexemes = [];
    final List<bool> isLexemeChinese = [];
    int start = 0;
    int end = 0;
    bool curLexemeChinese = _isChinese(text[0]);
    for (var i = 1; i < text.length; ++i) {
      if (curLexemeChinese == _isChinese(text[i])) {
        end += 1;
      } else {
        lexemes.add(text.substring(start, end + 1));
        isLexemeChinese.add(curLexemeChinese);
        start = i;
        end = i;
        curLexemeChinese = !curLexemeChinese;
      }
    }
    lexemes.add(text.substring(start, end + 1));
    isLexemeChinese.add(curLexemeChinese);

    return <dynamic>[lexemes, isLexemeChinese];
  }

  /// Break text into chinese/non-chinese lexemes
  bool _isChinese(String ch) {
    return ch.codeUnitAt(0) > 255;
  }

  /// Generate multiple bytes for a number in little-endian order.
  /// [value] is the input number.
  /// [bytesNb] is the number of bytes to output (1 - 4)
  List<int> _intLowHigh(int value, int bytesNb) {
    if (bytesNb < 1 || bytesNb > 4) {
      throw Exception('Can only output 1-4 bytes');
    }

    final int maxInput = (1 << (bytesNb * 8)) - 1;

    if (value < 0 || value > maxInput) {
      throw Exception(
          'Number is too large. Can only output up to $maxInput in $bytesNb bytes');
    }

    final List<int> res = <int>[];
    int buf = value;

    for (int i = 0; i < bytesNb; ++i) {
      res.add(buf & 0xFF); // lấy byte thấp
      buf = buf >> 8; // shift sang byte tiếp theo
    }

    return res;
  }

  /// Extract slices of an image as equal-sized blobs of column-format data.
  ///
  /// [image] Image to extract from
  /// [lineHeight] Printed line height in dots
  List<List<int>> _toColumnFormat(Image imgSrc, int lineHeight) {
    final Image image = Image.from(imgSrc); // make a copy

    // Determine new width: closest integer that is divisible by lineHeight, if diviable 8 then keep it
    final int widthPx = image.width % lineHeight == 0
        ? image.width
        : (image.width + lineHeight) - (image.width % lineHeight);
    final int heightPx = image.height;

    // Create a black bottom layer
    Image biggerImage = copyResize(image,
        width: widthPx, height: heightPx, interpolation: Interpolation.linear);
    //fill(biggerImage, color: ColorRgb8(0, 0, 0));
    biggerImage = fill(biggerImage, color: ColorRgb8(0, 0, 0));
    // Insert source image into bigger one
    biggerImage = compositeImage(biggerImage, image, dstX: 0, dstY: 0);

    int left = 0;
    final List<List<int>> blobs = [];

    while (left < widthPx) {
      final Image slice = copyCrop(biggerImage,
          x: left, y: 0, width: lineHeight, height: heightPx);
      if (slice.numChannels > 2) grayscale(slice);
      final imgBinary =
          (slice.numChannels > 1) ? slice.convert(numChannels: 1) : slice;
      final bytes = imgBinary.getBytes();
      blobs.add(bytes);
      left += lineHeight;
    }

    return blobs;
  }

  /// Image rasterization
  List<int> _toRasterFormat(Image imgSrc) {
    final Image image = Image.from(imgSrc); // make a copy
    final int widthPx = image.width;
    final int heightPx = image.height;

    // Determine new width: closest integer that is divisible by lineHeight, if not diviable 8 then increase
    final targetWidth = (widthPx + 7) & ~7;

    // Create a black bottom layer
    Image biggerImage = copyResize(image,
        width: targetWidth,
        height: heightPx,
        interpolation: Interpolation.linear);
    //fill(biggerImage, color: ColorRgb8(0, 0, 0));
    biggerImage = fill(biggerImage, color: ColorRgb8(255, 255, 255));
    // Insert source image into bigger one
    biggerImage = compositeImage(biggerImage, image, dstX: 0, dstY: 0);

    biggerImage = grayscale(biggerImage);
    biggerImage = invert(biggerImage);

    // R/G/B channels are same -> keep only one channel
    List<int> oneChannelBytes = [];
    final List<int> buffer = biggerImage.getBytes(order: ChannelOrder.rgba);
    for (int i = 0; i < buffer.length; i += 4) {
      oneChannelBytes.add(buffer[i]);
    }

    // Pack bits into bytes
    return _packBitsIntoBytes(oneChannelBytes);
  }

  /// Merges each 8 values (bits) into one byte
  List<int> _packBitsIntoBytes(List<int> pixels) {
    final List<int> res = [];
    const int threshold = 127;
    const int pxPerLine = 8;
    for (int i = 0; i < pixels.length; i += pxPerLine) {
      int byte = 0;
      for (int b = 0; b < pxPerLine; b++) {
        int idx = i + b;
        int bit = 0;
        if (idx < pixels.length) {
          // 1 = đen, 0 = trắng (nếu in ngược thì đảo lại)
          bit = (pixels[idx] > threshold) ? 1 : 0;
        }
        byte = (byte << 1) | bit;
      }
      res.add(byte);
    }
    return res;
  }

  // ************************ (end) Internal helpers  ************************

  //**************************** Public command generators ************************
  /// Clear the buffer and reset text styles
  List<int> reset() {
    List<int> bytes = [];
    bytes += cInit.codeUnits;
    _styles = const PosStyles();
    bytes += setGlobalCodeTable(_codeTable);
    bytes += setGlobalFont(_font);
    return bytes;
  }

  /// Clear the buffer and reset text styles
  List<int> clearStyle() {
    return setStyles(
        const PosStyles(height: PosTextSize.size1, width: PosTextSize.size1));
  }

  /// Set global code table which will be used instead of the default printer's code table
  /// (even after resetting)
  List<int> setGlobalCodeTable(String? codeTable) {
    List<int> bytes = [];
    _codeTable = codeTable;
    if (codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)..add(_profile.getCodePageId(codeTable)),
      );
      _styles = _styles.copyWith(codeTable: codeTable);
    }
    return bytes;
  }

  /// Set global font which will be used instead of the default printer's font
  /// (even after resetting)
  List<int> setGlobalFont(PosFontType? font, {int? maxCharsPerLine}) {
    List<int> bytes = [];
    _font = font;
    if (font != null) {
      _maxCharsPerLine = maxCharsPerLine ?? _getMaxCharsPerLine(font);
      bytes += font == PosFontType.fontB ? cFontB.codeUnits : cFontA.codeUnits;
      _styles = _styles.copyWith(fontType: font);
    }
    return bytes;
  }

  List<int> setStyles(PosStyles styles, {bool isKanji = false}) {
    List<int> bytes = [];
    if (styles.align != _styles.align) {
      bytes += codec.encode(styles.align == PosAlign.left
          ? cAlignLeft
          : (styles.align == PosAlign.center ? cAlignCenter : cAlignRight));
      _styles = _styles.copyWith(align: styles.align);
    }

    if (styles.bold != _styles.bold) {
      bytes += styles.bold ? cBoldOn.codeUnits : cBoldOff.codeUnits;
      _styles = _styles.copyWith(bold: styles.bold);
    }
    if (styles.turn90 != _styles.turn90) {
      bytes += styles.turn90 ? cTurn90On.codeUnits : cTurn90Off.codeUnits;
      _styles = _styles.copyWith(turn90: styles.turn90);
    }
    if (styles.reverse != _styles.reverse) {
      bytes += styles.reverse ? cReverseOn.codeUnits : cReverseOff.codeUnits;
      _styles = _styles.copyWith(reverse: styles.reverse);
    }
    if (styles.underline != _styles.underline) {
      bytes +=
          styles.underline ? cUnderline1dot.codeUnits : cUnderlineOff.codeUnits;
      _styles = _styles.copyWith(underline: styles.underline);
    }

    // Set font
    if (styles.fontType != null && styles.fontType != _styles.fontType) {
      bytes += styles.fontType == PosFontType.fontB
          ? cFontB.codeUnits
          : cFontA.codeUnits;
      _styles = _styles.copyWith(fontType: styles.fontType);
    } else if (_font != null && _font != _styles.fontType) {
      bytes += _font == PosFontType.fontB ? cFontB.codeUnits : cFontA.codeUnits;
      _styles = _styles.copyWith(fontType: _font);
    }

    // Characters size
    if (styles.height.value != _styles.height.value ||
        styles.width.value != _styles.width.value) {
      bytes += Uint8List.fromList(
        List.from(cSizeGSn.codeUnits)
          ..add(PosTextSize.decSize(styles.height, styles.width)),
      );
      _styles = _styles.copyWith(height: styles.height, width: styles.width);
    }

    // Set Kanji mode
    if (isKanji) {
      bytes += cKanjiOn.codeUnits;
    } else {
      bytes += cKanjiOff.codeUnits;
    }

    // Set local code table
    if (styles.codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)
          ..add(_profile.getCodePageId(styles.codeTable)),
      );
      _styles =
          _styles.copyWith(align: styles.align, codeTable: styles.codeTable);
    } else if (_codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)
          ..add(_profile.getCodePageId(_codeTable)),
      );
      _styles = _styles.copyWith(align: styles.align, codeTable: _codeTable);
    }

    return bytes;
  }

  /// Send raw command(s)
  List<int> rawBytes(List<int> cmd, {bool isKanji = false}) {
    List<int> bytes = [];
    if (!isKanji) {
      bytes += cKanjiOff.codeUnits;
    }
    bytes += Uint8List.fromList(cmd);
    return bytes;
  }

  List<int> text(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    bool containsChinese = false,
    int? maxCharsPerLine,
  }) {
    List<int> bytes = [];
    if (!containsChinese) {
      bytes += _text(
        _encode(text, isKanji: containsChinese),
        styles: styles,
        isKanji: containsChinese,
        maxCharsPerLine: maxCharsPerLine,
      );
      // Ensure at least one line break after the text
      bytes += emptyLines(linesAfter + 1);
    } else {
      bytes += _mixedKanji(text, styles: styles, linesAfter: linesAfter);
    }
    return bytes;
  }

  /// Skips [n] lines
  ///
  /// Similar to [feed] but uses an alternative command
  List<int> emptyLines(int n) {
    List<int> bytes = [];
    if (n > 0) {
      bytes += List.filled(n, '\n').join().codeUnits;
    }
    return bytes;
  }

  /// Skips [n] lines
  ///
  /// Similar to [emptyLines] but uses an alternative command
  List<int> feed(int n) {
    List<int> bytes = [];
    if (n >= 0 && n <= 255) {
      bytes += Uint8List.fromList(
        List.from(cFeedN.codeUnits)..add(n),
      );
    }
    return bytes;
  }

  /// Cut the paper
  ///
  /// [mode] is used to define the full or partial cut (if supported by the printer)
  List<int> cut({PosCutMode mode = PosCutMode.full}) {
    List<int> bytes = [];
    bytes += emptyLines(5);
    if (mode == PosCutMode.partial) {
      bytes += cCutPart.codeUnits;
    } else {
      bytes += cCutFull.codeUnits;
    }
    return bytes;
  }

  /// Print selected code table.
  ///
  /// If [codeTable] is null, global code table is used.
  /// If global code table is null, default printer code table is used.
  List<int> printCodeTable({String? codeTable}) {
    List<int> bytes = [];
    bytes += cKanjiOff.codeUnits;

    if (codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)..add(_profile.getCodePageId(codeTable)),
      );
    }

    bytes += Uint8List.fromList(List<int>.generate(256, (i) => i));

    // Back to initial code table
    setGlobalCodeTable(_codeTable);
    return bytes;
  }

  /// Beeps [n] times
  ///
  /// Beep [duration] could be between 50 and 450 ms.
  List<int> beep(
      {int n = 3, PosBeepDuration duration = PosBeepDuration.beep450ms}) {
    List<int> bytes = [];
    if (n <= 0) {
      return [];
    }

    int beepCount = n;
    if (beepCount > 9) {
      beepCount = 9;
    }

    bytes += Uint8List.fromList(
      List.from(cBeep.codeUnits)..addAll([beepCount, duration.value]),
    );

    beep(n: n - 9, duration: duration);
    return bytes;
  }

  /// Reverse feed for [n] lines (if supported by the printer)
  List<int> reverseFeed(int n) {
    List<int> bytes = [];
    bytes += Uint8List.fromList(
      List.from(cReverseFeedN.codeUnits)..add(n),
    );
    return bytes;
  }

  /// Print a row.
  ///
  /// A row contains up to 12 columns. A column has a width between 1 and 12.
  /// Total width of columns in one row must be equal 12.
  List<int> row(List<PosColumn> cols, {bool multiLine = true}) {
    List<int> bytes = [];
    final isSumValid = cols.fold(0, (int sum, col) => sum + col.width) == 12;
    if (!isSumValid) {
      throw Exception('Total columns width must be equal to 12');
    }
    bool isNextRow = false;
    List<PosColumn> nextRow = <PosColumn>[];

    for (int i = 0; i < cols.length; ++i) {
      int colInd =
          cols.sublist(0, i).fold(0, (int sum, col) => sum + col.width);
      double charWidth = _getCharWidth(cols[i].styles);
      double fromPos = _colIndToPosition(colInd);
      final double toPos =
          _colIndToPosition(colInd + cols[i].width) - spaceBetweenRows;
      int maxCharactersNb = ((toPos - fromPos) / charWidth).floor();

      if (!cols[i].containsChinese) {
        // CASE 1: containsChinese = false
        Uint8List encodedToPrint = cols[i].textEncoded != null
            ? cols[i].textEncoded!
            : _encode(cols[i].text);

        // If the col's content is too long, split it to the next row
        if (multiLine) {
          int realCharactersNb = encodedToPrint.length;
          if (realCharactersNb > maxCharactersNb) {
            // Print max possible and split to the next row
            Uint8List encodedToPrintNextRow =
                encodedToPrint.sublist(maxCharactersNb);
            encodedToPrint = encodedToPrint.sublist(0, maxCharactersNb);
            isNextRow = true;
            nextRow.add(PosColumn(
                textEncoded: encodedToPrintNextRow,
                width: cols[i].width,
                styles: cols[i].styles));
          } else {
            // Insert an empty col
            nextRow.add(PosColumn(
                text: '', width: cols[i].width, styles: cols[i].styles));
          }
        }
        // end rows splitting
        bytes += _text(
          encodedToPrint,
          styles: cols[i].styles,
          colInd: colInd,
          colWidth: cols[i].width,
        );
      } else {
        // CASE 1: containsChinese = true
        // Split text into multiple lines if it too long
        int counter = 0;
        int splitPos = 0;
        for (int p = 0; p < cols[i].text.length; ++p) {
          final int w = _isChinese(cols[i].text[p]) ? 2 : 1;
          if (counter + w >= maxCharactersNb) {
            break;
          }
          counter += w;
          splitPos += 1;
        }
        String toPrintNextRow = cols[i].text.substring(splitPos);
        String toPrint = cols[i].text.substring(0, splitPos);

        if (toPrintNextRow.isNotEmpty) {
          isNextRow = true;
          nextRow.add(PosColumn(
              text: toPrintNextRow,
              containsChinese: true,
              width: cols[i].width,
              styles: cols[i].styles));
        } else {
          // Insert an empty col
          nextRow.add(PosColumn(
              text: '', width: cols[i].width, styles: cols[i].styles));
        }

        // Print current row
        final list = _getLexemes(toPrint);
        final List<String> lexemes = list[0];
        final List<bool> isLexemeChinese = list[1];

        // Print each lexeme using codetable OR kanji
        int? colIndex = colInd;
        for (var j = 0; j < lexemes.length; ++j) {
          bytes += _text(
            _encode(lexemes[j], isKanji: isLexemeChinese[j]),
            styles: cols[i].styles,
            colInd: colIndex,
            colWidth: cols[i].width,
            isKanji: isLexemeChinese[j],
          );
          // Define the absolute position only once (we print one line only)
          colIndex = null;
        }
      }
    }

    bytes += emptyLines(1);

    if (isNextRow) {
      bytes += row(nextRow);
    }
    return bytes;
  }

  /// Print an image using (ESC *) command
  ///
  /// [image] is an instance of class from [Image library](https://pub.dev/packages/image)
  List<int> image(
    Image imgSrc, {
    PosAlign align = PosAlign.center,
    bool isDoubleDensity = true,
    int? paperMM,
  }) {
    final List<int> bytes = [];
    bytes.addAll(setStyles(const PosStyles().copyWith(align: align)));

    // 1. Xác định chiều rộng giấy
    const double dotsPerMm = 203.0 / 25.4;
    final int paperWidthMm = paperMM ??
        const {
          PaperSize.mm58: 56,
          PaperSize.mm72: 70,
          PaperSize.mm80: 76,
        }[_paperSize] ??
        76;

    final int targetWidthPx = (paperWidthMm * dotsPerMm).round();

    // 2. Resize + invert + rotate + flip (kết hợp nếu được)
    Image image = copyResize(imgSrc,
        width: targetWidthPx, interpolation: Interpolation.linear);
    image = invert(flipHorizontal(copyRotate(image, angle: 270)));

    // 3. Chọn độ nét
    final int lineHeight = isDoubleDensity ? 3 : 1;
    final List<List<int>> blobs = _toColumnFormat(image, lineHeight * 8);

    // 4. Nén dữ liệu
    for (int i = 0; i < blobs.length; i++) {
      blobs[i] = _packBitsIntoBytes(blobs[i]);
    }

    // 5. Header ESC/POS
    final int densityByte =
        (isDoubleDensity ? 1 : 0) + (isDoubleDensity ? 32 : 0);
    final List<int> header = [
      ...cBitImg.codeUnits,
      densityByte,
      ..._intLowHigh(image.height, 2),
    ];

    // 6. Gửi dữ liệu
    bytes.addAll([27, 51, 0]); // ESC 3 0
    for (final blob in blobs) {
      bytes.addAll(header);
      bytes.addAll(blob);
      bytes.add(10); // '\n'
    }
    bytes.addAll([27, 50]); // ESC 2 reset line feed

    return bytes;
  }

  /// Print an image using (GS v 0) obsolete command
  ///
  /// [image] is an instanse of class from [Image library](https://pub.dev/packages/image)
  List<int> imageRaster(
    Image imgSrc, {
    PosAlign align = PosAlign.center,
    bool highDensityHorizontal = true,
    bool highDensityVertical = true,
    PosImageFn imageFn = PosImageFn.bitImageRaster,
    int? paperMM,
  }) {
    List<int> bytes = [];

    // 1. Canh lề
    bytes += setStyles(const PosStyles().copyWith(align: align));

    // 2. Tính targetWidthPx theo paperSize
    final double dotsPerMm = 203.0 / 25.4;
    final int paperMm = paperMM ??
        switch (_paperSize) {
          PaperSize.mm58 => 56, // vùng in thực tế
          PaperSize.mm72 => 70,
          PaperSize.mm80 => 76,
          _ => 76,
        };
    final int targetWidthPx = (paperMm * dotsPerMm).round();

    // 3. Resize hình, giữ tỷ lệ
    final double ratio = targetWidthPx / imgSrc.width;
    final int targetHeightPx = (imgSrc.height * ratio).round();
    final Image image = copyResize(
      imgSrc,
      width: targetWidthPx,
      height: targetHeightPx,
      interpolation: Interpolation.linear,
    );

    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = (widthPx + 7) ~/ 8;

    // 4. Raster hóa ảnh
    final List<int> rasterizedData = _toRasterFormat(image);

    if (imageFn == PosImageFn.bitImageRaster) {
      final int densityByte =
          (highDensityVertical ? 0 : 1) + (highDensityHorizontal ? 0 : 2);

      // 5. Chia dữ liệu thành các chunk nhỏ (mỗi chunk 24 pixel)
      const int chunkHeight = 24;
      for (int y = 0; y < heightPx; y += chunkHeight) {
        final int h =
            (y + chunkHeight <= heightPx) ? chunkHeight : heightPx - y;
        final List<int> chunk =
            rasterizedData.sublist(y * widthBytes, (y + h) * widthBytes);

        final List<int> header = List.from(cRasterImg2.codeUnits);
        header.add(densityByte);
        header.addAll(_intLowHigh(widthBytes, 2));
        header.addAll(_intLowHigh(h, 2));

        bytes += List.from(header)..addAll(chunk);
      }
    } else if (imageFn == PosImageFn.graphics) {
      // Graphics mode (cũ)
      final List<int> header1 = List.from(cRasterImg.codeUnits);
      header1.addAll(_intLowHigh(widthBytes * heightPx + 10, 2));
      header1.addAll([48, 112, 48]);
      header1.addAll([1, 1]);
      header1.addAll([49]);
      header1.addAll(_intLowHigh(widthBytes, 2));
      header1.addAll(_intLowHigh(heightPx, 2));
      bytes += List.from(header1)..addAll(rasterizedData);

      final List<int> header2 = List.from(cRasterImg.codeUnits);
      header2.addAll([2, 0]);
      header2.addAll([48, 50]);
      bytes += List.from(header2);
    }

    // 6. Reset line spacing
    bytes += [27, 50];

    return bytes;
  }

  /// Convert Image -> ZPL (^GFA ...) as raw bytes
  List<int> imageToZpl(Image image, {int x = 0, int y = 0}) {
    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = ((widthPx + 7) ~/ 8);
    final int totalBytes = widthBytes * heightPx;

    final List<int> raster = _toRasterFormat(image);

    // pad/cut nếu cần
    final data = List<int>.filled(totalBytes, 0);
    for (int i = 0; i < raster.length && i < totalBytes; i++) {
      data[i] = raster[i];
    }

    final hex = StringBuffer();
    for (final b in data) {
      hex.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }

    final sb = StringBuffer();
    sb.writeln('^XA');
    sb.writeln('^FO$x,$y');
    sb.writeln('^GFA,$totalBytes,$totalBytes,$widthBytes,${hex.toString()}');
    sb.writeln('^FS');
    sb.writeln('^XZ');

    return utf8.encode(sb.toString());
  }

  /// Convert Image -> TSPL (BITMAP ...) as raw bytes
  List<int> imageToTspl(Image image, {int x = 0, int y = 0, int mode = 0}) {
    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = ((widthPx + 7) ~/ 8);
    final int totalBytes = widthBytes * heightPx;

    final List<int> raster = _toRasterFormat(image);

    final data = List<int>.filled(totalBytes, 0);
    for (int i = 0; i < raster.length && i < totalBytes; i++) {
      data[i] = raster[i];
    }

    final hex = StringBuffer();
    for (final b in data) {
      hex.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }

    final sb = StringBuffer();
    sb.writeln('CLS');
    sb.writeln('BITMAP $x,$y,$widthBytes,$heightPx,$mode,${hex.toString()}');
    sb.writeln('PRINT 1,1');

    return utf8.encode(sb.toString());
  }

  /// Print a barcode
  ///
  /// [width] range and units are different depending on the printer model (some printers use 1..5).
  /// [height] range: 1 - 255. The units depend on the printer model.
  /// Width, height, font, text position settings are effective until performing of ESC @, reset or power-off.
  List<int> barcode(
    Barcode barcode, {
    int? width,
    int? height,
    BarcodeFont? font,
    BarcodeText textPos = BarcodeText.below,
    PosAlign align = PosAlign.center,
  }) {
    List<int> bytes = [];
    // Set alignment
    bytes += setStyles(const PosStyles().copyWith(align: align));

    // Set text position
    bytes += cBarcodeSelectPos.codeUnits + [textPos.value];

    // Set font
    if (font != null) {
      bytes += cBarcodeSelectFont.codeUnits + [font.value];
    }

    // Set width
    if (width != null && width >= 0) {
      bytes += cBarcodeSetW.codeUnits + [width];
    }
    // Set height
    if (height != null && height >= 1 && height <= 255) {
      bytes += cBarcodeSetH.codeUnits + [height];
    }

    // Print barcode
    final header = cBarcodePrint.codeUnits + [barcode.type.value];
    if (barcode.type.value <= 6) {
      // Function A
      bytes += header + barcode.data + [0];
    } else {
      // Function B
      bytes += header + [barcode.data.length] + barcode.data;
    }
    return bytes;
  }

  /// Print a QR Code
  List<int> qrcode(
    String text, {
    PosAlign align = PosAlign.center,
    QRSize size = QRSize.size4,
    QRCorrection cor = QRCorrection.L,
  }) {
    List<int> bytes = [];
    // Set alignment
    bytes += setStyles(const PosStyles().copyWith(align: align));
    QRCode qr = QRCode(text, size, cor);
    bytes += qr.bytes;
    return bytes;
  }

  //0 - 17
  //or 48 - 59
  //TM-T82II  m = 0 – 11, 48 – 59
  List<int> printSpeech(int level) {
    List<int> bytes = [];
    // FN 167. QR Code: Set the size of module
    // pL pH fn m
    bytes += cControlHeader.codeUnits + [0x02, 0x00, 0x32, level];
    return bytes;
  }

  /// Open cash drawer
  List<int> drawer({PosDrawer pin = PosDrawer.pin2}) {
    List<int> bytes = [];
    if (pin == PosDrawer.pin2) {
      bytes += cCashDrawerPin2.codeUnits;
    } else {
      bytes += cCashDrawerPin5.codeUnits;
    }
    return bytes;
  }

  /// Print horizontal full width separator
  /// If [len] is null, then it will be defined according to the paper width
  List<int> hr({String ch = '-', int? len, int linesAfter = 0}) {
    List<int> bytes = [];
    int n = len ?? _maxCharsPerLine ?? _getMaxCharsPerLine(_styles.fontType);
    String ch1 = ch.length == 1 ? ch : ch[0];
    bytes += text(List.filled(n, ch1).join(), linesAfter: linesAfter);
    return bytes;
  }

  List<int> textEncoded(
    Uint8List textBytes, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
  }) {
    List<int> bytes = [];
    bytes += _text(textBytes, styles: styles, maxCharsPerLine: maxCharsPerLine);
    // Ensure at least one line break after the text
    bytes += emptyLines(linesAfter + 1);
    return bytes;
  }
  // ************************ (end) Public command generators ************************

  // ************************ (end) Internal command generators ************************
  /// Generic print for internal use
  ///
  /// [colInd] range: 0..11. If null: do not define the position
  List<int> _text(
    Uint8List textBytes, {
    PosStyles styles = const PosStyles(),
    int? colInd = 0,
    bool isKanji = false,
    int colWidth = 12,
    int? maxCharsPerLine,
  }) {
    List<int> bytes = [];
    if (colInd != null) {
      double charWidth =
          _getCharWidth(styles, maxCharsPerLine: maxCharsPerLine);
      double fromPos = _colIndToPosition(colInd);

      // Align
      if (colWidth != 12) {
        // Update fromPos
        final double toPos =
            _colIndToPosition(colInd + colWidth) - spaceBetweenRows;
        final double textLen = textBytes.length * charWidth;

        if (styles.align == PosAlign.right) {
          fromPos = toPos - textLen;
        } else if (styles.align == PosAlign.center) {
          fromPos = fromPos + (toPos - fromPos) / 2 - textLen / 2;
        }
        if (fromPos < 0) {
          fromPos = 0;
        }
      }

      final hexStr = fromPos.round().toRadixString(16).padLeft(3, '0');
      final hexPair = HEX.decode(hexStr);

      // Position
      bytes += Uint8List.fromList(
        List.from(cPos.codeUnits)..addAll([hexPair[1], hexPair[0]]),
      );
    }

    bytes += setStyles(styles, isKanji: isKanji);

    bytes += textBytes;
    return bytes;
  }

  /// Prints one line of styled mixed (chinese and latin symbols) text
  List<int> _mixedKanji(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
  }) {
    List<int> bytes = [];
    final list = _getLexemes(text);
    final List<String> lexemes = list[0];
    final List<bool> isLexemeChinese = list[1];

    // Print each lexeme using codetable OR kanji
    int? colInd = 0;
    for (var i = 0; i < lexemes.length; ++i) {
      bytes += _text(
        _encode(lexemes[i], isKanji: isLexemeChinese[i]),
        styles: styles,
        colInd: colInd,
        isKanji: isLexemeChinese[i],
        maxCharsPerLine: maxCharsPerLine,
      );
      // Define the absolute position only once (we print one line only)
      colInd = null;
    }

    bytes += emptyLines(linesAfter + 1);
    return bytes;
  }
// ************************ (end) Internal command generators ************************
}
