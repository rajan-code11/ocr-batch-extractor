import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive_io.dart';
import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

void main() {
  runApp(const OCRBatchExtractorApp());
}

class OCRBatchExtractorApp extends StatelessWidget {
  const OCRBatchExtractorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCR Batch Extractor',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const BatchOCRHomePage(),
    );
  }
}

enum ExtractionType { all, onlyText, onlyNumbers, digits7plus }

class _ImageCropData {
  final int x;
  final int y;
  final int width;
  final int height;
  _ImageCropData(this.x, this.y, this.width, this.height);
}

class BatchOCRHomePage extends StatefulWidget {
  const BatchOCRHomePage({super.key});
  @override
  State<BatchOCRHomePage> createState() => _BatchOCRHomePageState();
}

class _BatchOCRHomePageState extends State<BatchOCRHomePage> {
  List<File> images = [];
  _ImageCropData? cropData;
  ExtractionType extractionType = ExtractionType.all;
  String outputFileName = "output.csv";
  String? outputPath;
  List<List<String>> outputRows = [];
  bool processing = false;

  Future<void> pickImagesOrZip() async {
    // Pick files (images or zip)
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'zip'],
    );
    if (result != null) {
      images.clear();
      File file = File(result.files.single.path!);
      if (file.path.endsWith('.zip')) {
        // Extract zip
        final bytes = await file.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        Directory dir = await getTemporaryDirectory();
        for (final f in archive) {
          if (f.isFile &&
              (f.name.endsWith('.jpg') ||
                  f.name.endsWith('.jpeg') ||
                  f.name.endsWith('.png'))) {
            final filename = f.name.split('/').last;
            final outFile = File('${dir.path}/$filename');
            await outFile.writeAsBytes(f.content as List<int>);
            images.add(outFile);
          }
        }
      } else {
        images.add(file);
      }
      images.sort((a, b) => a.path.compareTo(b.path));
      setState(() {});
      if (images.isNotEmpty) {
        await cropFirstImage(images.first);
      }
    }
  }

  Future<void> cropFirstImage(File imageFile) async {
    // Crop first image to get crop rectangle
    final cropped = await ImageCropper().cropImage(
      sourcePath: imageFile.path,
      aspectRatioPresets: [CropAspectRatioPreset.original],
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop First Image',
          lockAspectRatio: false,
        ),
      ],
    );
    if (cropped != null) {
      // Calculate crop rectangle
      final origImg = img.decodeImage(File(imageFile.path).readAsBytesSync())!;
      final cropImg = img.decodeImage(File(cropped.path).readAsBytesSync())!;
      final x = ((origImg.width - cropImg.width) / 2).round();
      final y = ((origImg.height - cropImg.height) / 2).round();
      cropData = _ImageCropData(x, y, cropImg.width, cropImg.height);
      // Replace first image by cropped image for preview
      images[0] = File(cropped.path);
      setState(() {});
    }
  }

  Future<File> _cropImageWithRect(File imageFile, _ImageCropData cropData) async {
    final bytes = await imageFile.readAsBytes();
    final original = img.decodeImage(bytes)!;
    final cropped = img.copyCrop(
  original,
  x: cropData.x,
  y: cropData.y,
  width: cropData.width,
  height: cropData.height,
);
    final output = File('${(await getTemporaryDirectory()).path}/${DateTime.now().millisecondsSinceEpoch}_${imageFile.path.split('/').last}');
    await output.writeAsBytes(img.encodeJpg(cropped));
    return output;
  }

  Future<void> runOCRandExport() async {
    if (images.isEmpty) return;
    setState(() => processing = true);

    outputRows.clear();
    List<File> croppedImages = [];
    // Apply crop to all images
    for (var i = 0; i < images.length; i++) {
      if (i == 0 && cropData != null) {
        croppedImages.add(images[0]);
      } else if (cropData != null) {
        croppedImages.add(await _cropImageWithRect(images[i], cropData!));
      } else {
        croppedImages.add(images[i]);
      }
    }

    // OCR each image
    for (File imgFile in croppedImages) {
      final inputImage = InputImage.fromFile(imgFile);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognizedText =
          await textRecognizer.processImage(inputImage);
      String text = recognizedText.text;
      String extracted = filterText(text, extractionType);
      outputRows.add([imgFile.path.split('/').last, extracted]);
    }
    outputRows.sort((a, b) => a[0].compareTo(b[0]));
    await exportCSV();
    setState(() => processing = false);
  }

  String filterText(String text, ExtractionType type) {
    switch (type) {
      case ExtractionType.all:
        return text.replaceAll('\n', ' ');
      case ExtractionType.onlyText:
        return text.replaceAll(RegExp(r'[0-9]'), '').replaceAll('\n', ' ').trim();
      case ExtractionType.onlyNumbers:
        return RegExp(r'\d+').allMatches(text).map((m) => m.group(0)).join(' ');
      case ExtractionType.digits7plus:
        return RegExp(r'\d{7,}').allMatches(text).map((m) => m.group(0)).join(' ');
    }
  }

  Future<void> exportCSV() async {
    final csvStr = const ListToCsvConverter().convert(outputRows);
    Directory dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    String savePath = "${dir.path}/$outputFileName";
    File outFile = File(savePath);
    await outFile.writeAsString(csvStr);
    setState(() {
      outputPath = savePath;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported to $outputFileName')));
  }

  Widget extractionTypeSelector() {
    return ExpansionTile(
      title: const Text("Extraction Type"),
      children: [
        RadioListTile(
          title: const Text("Extract all text & numbers"),
          value: ExtractionType.all,
          groupValue: extractionType,
          onChanged: (val) => setState(() => extractionType = val!),
        ),
        RadioListTile(
          title: const Text("Only text (no numbers)"),
          value: ExtractionType.onlyText,
          groupValue: extractionType,
          onChanged: (val) => setState(() => extractionType = val!),
        ),
        RadioListTile(
          title: const Text("Only numbers (no text)"),
          value: ExtractionType.onlyNumbers,
          groupValue: extractionType,
          onChanged: (val) => setState(() => extractionType = val!),
        ),
        RadioListTile(
          title: const Text("Only 7+ digit numbers"),
          value: ExtractionType.digits7plus,
          groupValue: extractionType,
          onChanged: (val) => setState(() => extractionType = val!),
        ),
      ],
    );
  }

  Future<void> pickTxtAndExtract7plus() async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt']);
    if (result != null && result.files.single.path != null) {
      final txtFile = File(result.files.single.path!);
      final content = await txtFile.readAsString();
      final matches = RegExp(r'\d{7,}').allMatches(content).map((m) => m.group(0)).join('\n');
      Directory dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      String savePath = "${dir.path}/fixed_7plus.txt";
      File outFile = File(savePath);
      await outFile.writeAsString(matches);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Extracted numbers saved as fixed_7plus.txt')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OCR Batch Extractor')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ElevatedButton(
              onPressed: processing ? null : pickImagesOrZip,
              child: const Text("Upload Images or Zip"),
            ),
            if (images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Image.file(images.first, height: 150),
              ),
            extractionTypeSelector(),
            TextField(
              decoration: InputDecoration(
                labelText: "Output File Name",
                hintText: "output.csv",
              ),
              onChanged: (v) => outputFileName = v,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: processing ? null : () async {
                await runOCRandExport();
              },
              child: processing ? const CircularProgressIndicator() : const Text("Run OCR and Export"),
            ),
            if (outputPath != null) Text("Saved at: $outputPath"),
            const Divider(height: 40),
            ElevatedButton(
              onPressed: processing ? null : pickTxtAndExtract7plus,
              child: const Text("Fix TXT File (Extract 7+ digit numbers)"),
            ),
          ],
        ),
      ),
    );
  }
}
