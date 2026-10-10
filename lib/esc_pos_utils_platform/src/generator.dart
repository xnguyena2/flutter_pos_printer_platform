import 'dart:convert';
import 'dart:typed_data' show Uint8List;
import 'package:image/image.dart';
import 'package:gbk_codec/gbk_codec.dart';
import '../flutter_esc_pos_utils.dart';
import 'commands.dart';

class Generator {
  Generator(
    this._paperSize,
    this._profile, {
    this.spaceBetweenRows = 5,
    this.codec = latin1,
  });

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

  // Bảng bỏ dấu tiếng Việt (dùng khi codec không encode được ký tự)
  static const Map<String, String> _viDiacritics = {
    'a': 'àáạảãâầấậẩẫăằắặẳẵ',
    'A': 'ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴ',
    'e': 'èéẹẻẽêềếệểễ',
    'E': 'ÈÉẸẺẼÊỀẾỆỂỄ',
    'i': 'ìíịỉĩ',
    'I': 'ÌÍỊỈĨ',
    'o': 'òóọỏõôồốộổỗơờớợởỡ',
    'O': 'ÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠ',
    'u': 'ùúụủũưừứựửữ',
    'U': 'ÙÚỤỦŨƯỪỨỰỬỮ',
    'y': 'ỳýỵỷỹ',
    'Y': 'ỲÝỴỶỸ',
    'd': 'đ',
    'D': 'Đ',
  };

  static final Map<int, String> _viLookup = () {
    final map = <int, String>{};
    _viDiacritics.forEach((base, chars) {
      for (final r in chars.runes) {
        map[r] = base;
      }
    });
    return map;
  }();

  /// Bỏ dấu tiếng Việt, kể cả dấu tổ hợp (NFD, U+0300..U+036F).
  static String removeVietnameseDiacritics(String text) {
    final sb = StringBuffer();
    for (final r in text.runes) {
      if (r >= 0x0300 && r <= 0x036F) continue; // dấu tổ hợp
      final mapped = _viLookup[r];
      if (mapped != null) {
        sb.write(mapped);
      } else {
        sb.writeCharCode(r);
      }
    }
    return sb.toString();
  }

  /// Encode an toàn: nếu codec không encode được (vd. latin1 gặp "ữ"),
  /// thì bỏ dấu tiếng Việt; ký tự nào vẫn không encode được thay bằng '?'.
  /// Trước đây trường hợp này ném ArgumentError và làm hỏng cả hóa đơn.
  Uint8List _safeEncode(String text) {
    try {
      return Uint8List.fromList(codec.encode(text));
    } catch (_) {
      final stripped = removeVietnameseDiacritics(text);
      try {
        return Uint8List.fromList(codec.encode(stripped));
      } catch (_) {
        final List<int> out = [];
        for (final r in stripped.runes) {
          final ch = String.fromCharCode(r);
          try {
            out.addAll(codec.encode(ch));
          } catch (_) {
            out.add(0x3F); // '?'
          }
        }
        return Uint8List.fromList(out);
      }
    }
  }

  Uint8List _encode(String text, {bool isKanji = false}) {
    // replace some non-ascii characters
    text = text
        .replaceAll("’", "'")
        .replaceAll("´", "'")
        .replaceAll("»", '"')
        .replaceAll("\u00A0", ' ')
        .replaceAll("•", '.');
    if (!isKanji) {
      return _safeEncode(text);
    } else {
      return Uint8List.fromList(gbk_bytes.encode(text));
    }
  }

  List _getLexemes(String text) {
    final List<String> lexemes = [];
    final List<bool> isLexemeChinese = [];
    if (text.isEmpty) {
      return <dynamic>[
        <String>[''],
        <bool>[false],
      ];
    }
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
        'Number is too large. Can only output up to $maxInput in $bytesNb bytes',
      );
    }

    final List<int> res = <int>[];
    int buf = value;

    for (int i = 0; i < bytesNb; ++i) {
      res.add(buf & 0xFF); // lấy byte thấp
      buf = buf >> 8; // shift sang byte tiếp theo
    }

    return res;
  }

  /// Đổ ảnh có kênh alpha lên nền trắng.
  /// Nếu không, pixel trong suốt (RGB = 0) sẽ bị in thành màu đen.
  Image _flattenOnWhite(Image src) {
    if (!src.hasAlpha) return src;
    final bg = Image(width: src.width, height: src.height, numChannels: 3)
      ..clear(ColorRgb8(255, 255, 255));
    return compositeImage(bg, src);
  }

  /// Chiều rộng in tính bằng dot.
  /// Nếu truyền [paperMM] thì tính theo 203 dpi, ngược lại dùng vùng in
  /// thực tế của khổ giấy (_paperSize.width) để ảnh không bị cắt mép.
  int _printableWidthPx(int? paperMM) {
    if (paperMM != null) {
      return (paperMM * 203.0 / 25.4).round();
    }
    return _paperSize.width;
  }

  Image _resizeToWidth(Image src, int targetWidthPx) {
    final double ratio = targetWidthPx / src.width;
    final int targetHeightPx = (src.height * ratio).round();
    return copyResize(
      src,
      width: targetWidthPx,
      height: targetHeightPx,
      interpolation: Interpolation.linear,
    );
  }

  /// Extract slices of an image as equal-sized blobs of column-format data.
  ///
  /// [image] Image to extract from
  /// [lineHeight] Printed line height in dots
  List<List<int>> _toColumnFormat(Image imgSrc, int lineHeight) {
    final Image image = imgSrc;

    // Chiều rộng mới: làm tròn lên bội số của lineHeight
    final int widthPx = image.width % lineHeight == 0
        ? image.width
        : (image.width + lineHeight) - (image.width % lineHeight);
    final int heightPx = image.height;

    // Nền đen (ảnh đã invert nên đen = không in), rồi chèn ảnh gốc vào
    Image biggerImage = Image(
      width: widthPx,
      height: heightPx,
      format: image.format,
      numChannels: image.numChannels,
    )..clear(ColorRgb8(0, 0, 0));
    biggerImage = compositeImage(biggerImage, image, dstX: 0, dstY: 0);

    int left = 0;
    final List<List<int>> blobs = [];

    while (left < widthPx) {
      final Image slice = copyCrop(
        biggerImage,
        x: left,
        y: 0,
        width: lineHeight,
        height: heightPx,
      );
      if (slice.numChannels > 2) grayscale(slice);
      final imgBinary = (slice.numChannels > 1)
          ? slice.convert(numChannels: 1)
          : slice;
      final bytes = imgBinary.getBytes();
      blobs.add(bytes);
      left += lineHeight;
    }

    return blobs;
  }

  /// Image rasterization.
  /// Kết quả: mỗi hàng widthBytes = ceil(width / 8) byte, MSB bên trái,
  /// bit 1 = điểm đen (quy ước ESC/POS và ZPL).
  List<int> _toRasterFormat(Image imgSrc) {
    Image image = _flattenOnWhite(imgSrc);
    if (image.format != Format.uint8) {
      image = image.convert(format: Format.uint8);
    }
    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = (widthPx + 7) >> 3;

    // Phần đệm bên phải để mặc định = 0 (trắng)
    final Uint8List out = Uint8List(widthBytes * heightPx);
    for (int y = 0; y < heightPx; y++) {
      final int rowOffset = y * widthBytes;
      for (int x = 0; x < widthPx; x++) {
        final p = image.getPixel(x, y);
        // Cùng phép tính với bản cũ: grayscale() lấy phần nguyên của
        // getLuminanceRgb, invert, rồi > 127  <=>  gray < 128.
        // Giữ đúng công thức để hóa đơn in ra y hệt trước đây.
        final int gray = getLuminanceRgb(p.r, p.g, p.b).clamp(0, 255).toInt();
        if (gray < 128) {
          out[rowOffset + (x >> 3)] |= 0x80 >> (x & 7);
        }
      }
    }
    return out;
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
      const PosStyles(height: PosTextSize.size1, width: PosTextSize.size1),
    );
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
      bytes += codec.encode(
        styles.align == PosAlign.left
            ? cAlignLeft
            : (styles.align == PosAlign.center ? cAlignCenter : cAlignRight),
      );
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
      bytes += styles.underline
          ? cUnderline1dot.codeUnits
          : cUnderlineOff.codeUnits;
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
      _styles = _styles.copyWith(
        align: styles.align,
        codeTable: styles.codeTable,
      );
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
      bytes += Uint8List.fromList(List.from(cFeedN.codeUnits)..add(n));
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

    // Back to initial code table (trước đây bytes trả về bị bỏ qua)
    bytes += setGlobalCodeTable(_codeTable);
    return bytes;
  }

  /// Beeps [n] times
  ///
  /// Beep [duration] could be between 50 and 450 ms.
  List<int> beep({
    int n = 3,
    PosBeepDuration duration = PosBeepDuration.beep450ms,
  }) {
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

    // Trước đây kết quả đệ quy bị bỏ qua nên n > 9 chỉ kêu 9 lần
    bytes += beep(n: n - 9, duration: duration);
    return bytes;
  }

  /// Reverse feed for [n] lines (if supported by the printer)
  List<int> reverseFeed(int n) {
    List<int> bytes = [];
    bytes += Uint8List.fromList(List.from(cReverseFeedN.codeUnits)..add(n));
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
      int colInd = cols
          .sublist(0, i)
          .fold(0, (int sum, col) => sum + col.width);
      double charWidth = _getCharWidth(cols[i].styles);
      double fromPos = _colIndToPosition(colInd);
      final double toPos =
          _colIndToPosition(colInd + cols[i].width) - spaceBetweenRows;
      int maxCharactersNb = ((toPos - fromPos) / charWidth).floor();
      // Cột quá hẹp (vd. width 1 + chữ size 3) -> 0 ký tự. Trước đây
      // row() gọi đệ quy mãi với cùng nội dung -> tràn stack.
      if (maxCharactersNb < 1) {
        maxCharactersNb = 1;
      }

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
            Uint8List encodedToPrintNextRow = encodedToPrint.sublist(
              maxCharactersNb,
            );
            encodedToPrint = encodedToPrint.sublist(0, maxCharactersNb);
            isNextRow = true;
            nextRow.add(
              PosColumn(
                textEncoded: encodedToPrintNextRow,
                width: cols[i].width,
                styles: cols[i].styles,
              ),
            );
          } else {
            // Insert an empty col
            nextRow.add(
              PosColumn(text: '', width: cols[i].width, styles: cols[i].styles),
            );
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
        // CASE 2: containsChinese = true
        // Split text into multiple lines if it too long
        int counter = 0;
        int splitPos = 0;
        for (int p = 0; p < cols[i].text.length; ++p) {
          final int w = _isChinese(cols[i].text[p]) ? 2 : 1;
          // Trước đây dùng >= nên mỗi cột mất 1 ký tự sức chứa
          // splitPos > 0: luôn in ít nhất 1 ký tự để không đệ quy vô hạn
          if (counter + w > maxCharactersNb && splitPos > 0) {
            break;
          }
          counter += w;
          splitPos += 1;
        }
        String toPrintNextRow = cols[i].text.substring(splitPos);
        String toPrint = cols[i].text.substring(0, splitPos);

        if (toPrintNextRow.isNotEmpty) {
          isNextRow = true;
          nextRow.add(
            PosColumn(
              text: toPrintNextRow,
              containsChinese: true,
              width: cols[i].width,
              styles: cols[i].styles,
            ),
          );
        } else {
          // Insert an empty col
          nextRow.add(
            PosColumn(text: '', width: cols[i].width, styles: cols[i].styles),
          );
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
  ///
  /// [lineFeedAfterSlice]: thêm LF sau mỗi dải 24 dot. Bản gốc
  /// flutter_esc_pos_utils có LF; một số máy tự đẩy giấy sau ESC * nên
  /// mặc định để false để giữ hành vi hiện tại. Nếu ảnh bị in chồng lên
  /// một dòng thì bật true.
  List<int> image(
    Image imgSrc, {
    PosAlign align = PosAlign.center,
    bool isDoubleDensity = true,
    int? paperMM,
    bool resizeToPaper = true,
    bool lineFeedAfterSlice = false,
  }) {
    List<int> bytes = [];
    bytes.addAll(setStyles(const PosStyles().copyWith(align: align)));

    // Không flatten ở đây: bản cũ invert rồi ghép lên nền đen trong
    // _toColumnFormat, pixel trong suốt vẫn ra "không in". Giữ nguyên thứ tự
    // cũ để hóa đơn (isOldModel = false) in ra y hệt trước đây.
    Image image = imgSrc;
    if (resizeToPaper) {
      image = _resizeToWidth(image, _printableWidthPx(paperMM));
    }

    image = invert(image);
    image = flipHorizontal(image);
    final Image imageRotated = copyRotate(image, angle: 270);

    int lineHeight = isDoubleDensity ? 3 : 1;
    final List<List<int>> blobs = _toColumnFormat(imageRotated, lineHeight * 8);

    // Compress according to line density
    // Line height contains 8 or 24 pixels of src image
    // Each blobs[i] contains greyscale bytes [0-255]
    for (int blobInd = 0; blobInd < blobs.length; blobInd++) {
      blobs[blobInd] = _packBitsIntoBytes(blobs[blobInd]);
    }

    final int heightPx = imageRotated.height;
    int densityByte = (isDoubleDensity ? 1 : 0) + (isDoubleDensity ? 32 : 0);

    final List<int> header = List.from(cBitImg.codeUnits);
    header.add(densityByte);
    header.addAll(_intLowHigh(heightPx, 2));

    // Line spacing = 0: ESC 3 0 (HEX: 0x1b 0x33 0x00)
    bytes += [27, 51, 0];
    for (int i = 0; i < blobs.length; ++i) {
      bytes += List.from(header)..addAll(blobs[i]);
      if (lineFeedAfterSlice) {
        bytes += [10]; // LF
      }
    }
    // Reset line spacing: ESC 2 (HEX: 0x1b 0x32)
    bytes += [27, 50];
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
    bool resizeToPaper = true,
  }) {
    List<int> bytes = [];

    // 1. Canh lề
    bytes += setStyles(const PosStyles().copyWith(align: align));
    Image image = _flattenOnWhite(imgSrc);
    if (resizeToPaper) {
      // 2. Resize theo vùng in thực tế, giữ tỷ lệ
      image = _resizeToWidth(image, _printableWidthPx(paperMM));
    }

    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = (widthPx + 7) ~/ 8;

    // 3. Raster hóa ảnh
    final List<int> rasterizedData = _toRasterFormat(image);

    if (imageFn == PosImageFn.bitImageRaster) {
      final int densityByte =
          (highDensityVertical ? 0 : 1) + (highDensityHorizontal ? 0 : 2);

      // 4. Chia dữ liệu thành các chunk nhỏ (mỗi chunk 24 pixel)
      const int chunkHeight = 24;
      for (int y = 0; y < heightPx; y += chunkHeight) {
        final int h = (y + chunkHeight <= heightPx)
            ? chunkHeight
            : heightPx - y;
        final List<int> chunk = rasterizedData.sublist(
          y * widthBytes,
          (y + h) * widthBytes,
        );

        final List<int> header = List.from(cRasterImg2.codeUnits);
        header.add(densityByte);
        header.addAll(_intLowHigh(widthBytes, 2));
        header.addAll(_intLowHigh(h, 2));

        bytes += List.from(header)..addAll(chunk);
      }
    } else if (imageFn == PosImageFn.graphics &&
        widthBytes > 0 &&
        heightPx > 0) {
      // Graphics mode (GS ( L). pL pH tối đa 65535 byte nên chia ảnh
      // thành nhiều band; trước đây ảnh lớn sẽ ném Exception.
      final int bandHeight = ((65535 - 10) ~/ widthBytes).clamp(1, heightPx);
      for (int y = 0; y < heightPx; y += bandHeight) {
        final int h = (y + bandHeight <= heightPx) ? bandHeight : heightPx - y;
        final List<int> band = rasterizedData.sublist(
          y * widthBytes,
          (y + h) * widthBytes,
        );

        // Lưu dữ liệu ảnh vào print buffer (fn 112)
        final List<int> header1 = List.from(cRasterImg.codeUnits);
        header1.addAll(_intLowHigh(widthBytes * h + 10, 2));
        header1.addAll([48, 112, 48]);
        header1.addAll([1, 1]);
        header1.addAll([49]);
        header1.addAll(_intLowHigh(widthBytes * 8, 2));
        header1.addAll(_intLowHigh(h, 2));
        bytes += List.from(header1)..addAll(band);

        // In dữ liệu đã lưu (fn 50)
        final List<int> header2 = List.from(cRasterImg.codeUnits);
        header2.addAll([2, 0]);
        header2.addAll([48, 50]);
        bytes += List.from(header2);
      }
    }

    // 5. Reset line spacing
    bytes += [27, 50];

    return bytes;
  }

  static final List<String> _hexTable = List<String>.generate(
    256,
    (i) => i.toRadixString(16).padLeft(2, '0').toUpperCase(),
  );

  /// Convert Image -> ZPL (^GFA ...) as raw bytes
  ///
  /// Gọi với tham số mặc định thì output giống bản cũ.
  /// Các tùy chọn dưới đây để xử lý máy in kén (máy clone, ZPL emulation):
  ///
  /// [printWidthDots]: thêm ^PW. Nên đặt bằng độ rộng nhãn theo dot
  ///   (vd. nhãn 4 inch @203 dpi = 812, nhãn 50 mm @203 dpi ≈ 400).
  /// [labelLengthDots]: thêm ^LL (chiều dài nhãn theo dot).
  /// [targetWidthPx]: resize ảnh về chiều rộng này, giữ tỷ lệ.
  /// [maxBytesPerField]: chia ảnh thành nhiều ^GFA xếp dọc, mỗi phần không
  ///   quá số byte này. Dùng cho máy bộ nhớ/buffer nhỏ (thử 8000–16000).
  /// [splitRows]: xuống dòng sau mỗi hàng dữ liệu hex thay vì một dòng
  ///   rất dài. Zebra bỏ qua CR/LF trong ZPL; giúp máy có line buffer ngắn.
  /// [wrapLabel]: false để chỉ trả về các field ^FO..^FS, ghép vào nhãn khác.
  /// [copies]: số bản in (^PQ).
  List<int> imageToZpl(
    Image image, {
    int x = 0,
    int y = 0,
    int? printWidthDots,
    int? labelLengthDots,
    int? targetWidthPx,
    int? maxBytesPerField,
    bool splitRows = false,
    bool wrapLabel = true,
    int copies = 1,
  }) {
    Image img = image;
    if (targetWidthPx != null &&
        targetWidthPx > 0 &&
        targetWidthPx != img.width) {
      img = _resizeToWidth(_flattenOnWhite(img), targetWidthPx);
    }

    final int widthPx = img.width;
    final int heightPx = img.height;
    final int widthBytes = (widthPx + 7) ~/ 8;
    if (widthPx == 0 || heightPx == 0) return [];

    // ZPL: bit 1 = đen, cùng quy ước với _toRasterFormat
    final List<int> data = _toRasterFormat(img);

    int rowsPerBand = heightPx;
    if (maxBytesPerField != null && maxBytesPerField > 0) {
      rowsPerBand = (maxBytesPerField ~/ widthBytes).clamp(1, heightPx);
    }

    final sb = StringBuffer();
    if (wrapLabel) {
      sb.writeln('^XA');
      if (printWidthDots != null) sb.writeln('^PW$printWidthDots');
      if (labelLengthDots != null) sb.writeln('^LL$labelLengthDots');
    }

    for (int top = 0; top < heightPx; top += rowsPerBand) {
      final int h = (top + rowsPerBand <= heightPx)
          ? rowsPerBand
          : heightPx - top;
      final int bandBytes = widthBytes * h;

      sb.writeln('^FO$x,${y + top}');
      sb.write('^GFA,$bandBytes,$bandBytes,$widthBytes,');
      if (splitRows) sb.writeln();
      for (int r = top; r < top + h; r++) {
        final int off = r * widthBytes;
        for (int i = off; i < off + widthBytes; i++) {
          sb.write(_hexTable[data[i]]);
        }
        if (splitRows) sb.writeln();
      }
      if (!splitRows) sb.writeln();
      sb.writeln('^FS');
    }

    if (wrapLabel) {
      if (copies > 1) sb.writeln('^PQ$copies');
      sb.writeln('^XZ');
    }

    return utf8.encode(sb.toString());
  }

  /// Convert Image -> TSPL (BITMAP ...) as raw bytes
  ///
  /// Chuẩn TSPL: dữ liệu BITMAP là byte nhị phân, bit 0 = điểm in (đen).
  ///
  /// [hexData] = true: gửi dạng chuỗi hex như code cũ, chỉ dùng nếu đã
  /// test máy của bạn in đúng với kiểu này.
  /// [labelWidthMm], [labelHeightMm], [gapMm]: nếu truyền thì thêm lệnh
  /// SIZE / GAP trước CLS.
  /// [referenceX]/[referenceY] -> REFERENCE, [direction] -> DIRECTION,
  /// [home] -> HOME (dò khe decal, chỉ cần cho khổ nhiều tem trên một hàng).
  /// Không truyền thì không thêm lệnh nào (giống hành vi cũ).
  List<int> imageToTspl(
    Image image, {
    int x = 0,
    int y = 0,
    int mode = 0,
    bool hexData = false,
    double? labelWidthMm,
    double? labelHeightMm,
    double? gapMm,
    int copies = 1,
    int? referenceX,
    int? referenceY,
    int? direction,
    bool home = false,
  }) {
    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = ((widthPx + 7) ~/ 8);

    final List<int> raster = _toRasterFormat(image);

    // 50.0 -> "50", 50.5 -> "50.5" (một số máy clone không nhận "50.0")
    String n(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toString();

    final sb = StringBuffer();
    if (labelWidthMm != null && labelHeightMm != null) {
      sb.write('SIZE ${n(labelWidthMm)} mm,${n(labelHeightMm)} mm\r\n');
    }
    if (gapMm != null) {
      sb.write('GAP ${n(gapMm)} mm,0 mm\r\n');
    }
    // Giống thư viện print_label: SIZE, GAP, REFERENCE, DIRECTION, [HOME], CLS.
    if (referenceX != null && referenceY != null) {
      sb.write('REFERENCE $referenceX,$referenceY\r\n');
    }
    if (direction != null) {
      sb.write('DIRECTION $direction\r\n');
    }
    if (home) {
      sb.write('HOME\r\n');
    }
    sb.write('CLS\r\n');
    sb.write('BITMAP $x,$y,$widthBytes,$heightPx,$mode,');

    final List<int> bytes = [];
    bytes.addAll(utf8.encode(sb.toString()));

    if (hexData) {
      // Hành vi cũ (không chuẩn TSPL)
      final hex = StringBuffer();
      for (final b in raster) {
        hex.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
      bytes.addAll(utf8.encode(hex.toString()));
    } else {
      // Chuẩn TSPL: nhị phân, đảo bit (0 = đen)
      for (final b in raster) {
        bytes.add((~b) & 0xFF);
      }
    }

    bytes.addAll(utf8.encode('\r\nPRINT $copies,1\r\n'));
    return bytes;
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

  /// Chọn tốc độ in: GS ( K pL pH fn m  (fn = 0x32)
  ///
  /// [level]: 0 - 17 hoặc 48 - 59 tùy máy
  /// (TM-T82II: m = 0 – 11, 48 – 59)
  List<int> printSpeed(int level) {
    List<int> bytes = [];
    bytes += cControlHeader.codeUnits + [0x02, 0x00, 0x32, level];
    return bytes;
  }

  /// Giữ lại để không làm hỏng code đang gọi tên cũ.
  @Deprecated('Dùng printSpeed()')
  List<int> printSpeech(int level) => printSpeed(level);

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
    String ch1 = ch.isEmpty ? '-' : ch[0];
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

  // ************************ Internal command generators ************************
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
      double charWidth = _getCharWidth(
        styles,
        maxCharsPerLine: maxCharsPerLine,
      );
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

      // Position: ESC $ nL nH (little-endian), không cần qua chuỗi hex
      final int pos = fromPos.round();
      bytes += Uint8List.fromList(
        List.from(cPos.codeUnits)..addAll([pos & 0xFF, (pos >> 8) & 0xFF]),
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
