package space.labbing.jarvisalerts;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.view.WindowManager;
import android.widget.ImageView;
import com.google.zxing.*;
import com.google.zxing.common.*;
import com.google.zxing.qrcode.QRCodeWriter;
import org.json.JSONObject;
import java.io.InputStream;

final class PairingQr {
    static JSONObject parse(String text) throws Exception {
        JSONObject value = new JSONObject(text);
        if (!"orbit-phone-pairing".equals(value.getString("format")) || value.getInt("version") != 1
            || !value.getString("key").matches("[a-f0-9]{64}")) throw new IllegalArgumentException();
        java.util.UUID.fromString(value.getString("device"));
        return value;
    }
    static JSONObject image(Context context, Uri uri) throws Exception {
        BitmapFactory.Options size = new BitmapFactory.Options();
        size.inJustDecodeBounds = true;
        try (InputStream in = context.getContentResolver().openInputStream(uri)) { BitmapFactory.decodeStream(in, null, size); }
        if (size.outWidth <= 0 || size.outHeight <= 0) throw new IllegalArgumentException();
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = 1;
        while (size.outWidth / options.inSampleSize > 2048 || size.outHeight / options.inSampleSize > 2048) options.inSampleSize *= 2;
        Bitmap bitmap;
        try (InputStream in = context.getContentResolver().openInputStream(uri)) { bitmap = BitmapFactory.decodeStream(in, null, options); }
        if (bitmap == null) throw new IllegalArgumentException();
        int width = bitmap.getWidth(), height = bitmap.getHeight();
        int[] pixels = new int[width * height];
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height);
        bitmap.recycle();
        Result result = new MultiFormatReader().decode(new BinaryBitmap(new HybridBinarizer(new RGBLuminanceSource(width, height, pixels))));
        return parse(result.getText());
    }
    static void display(Activity activity) {
        new AlertDialog.Builder(activity).setTitle("Display private pairing QR?")
            .setMessage("This QR contains your companion credential. Anyone who scans it can use the same phone pairing. Display it only during your own setup.")
            .setNegativeButton("Cancel", null).setPositiveButton("Display", (d,w) -> {
                try {
                    String key = AlertService.prefs(activity).getString("key", "");
                    String device = AlertService.prefs(activity).getString("device", "");
                    JSONObject value = new JSONObject().put("format", "orbit-phone-pairing").put("version", 1).put("key", key).put("device", device);
                    parse(value.toString());
                    BitMatrix matrix = new QRCodeWriter().encode(value.toString(), BarcodeFormat.QR_CODE, 600, 600);
                    Bitmap bitmap = Bitmap.createBitmap(600, 600, Bitmap.Config.ARGB_8888);
                    int[] pixels = new int[360000];
                    for (int y=0;y<600;y++) for(int x=0;x<600;x++) pixels[y*600+x] = matrix.get(x,y) ? 0xff000000 : 0xffffffff;
                    bitmap.setPixels(pixels, 0, 600, 0, 0, 600, 600);
                    ImageView image = new ImageView(activity);
                    image.setImageBitmap(bitmap);
                    image.setAdjustViewBounds(true);
                    image.setPadding(16,16,16,16);
                    AlertDialog dialog = new AlertDialog.Builder(activity).setTitle("Private pairing QR").setView(image).setPositiveButton("Close", null).create();
                    dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
                    dialog.setOnDismissListener(ignored -> bitmap.recycle());
                    dialog.show();
                } catch (Exception error) { android.widget.Toast.makeText(activity, "A saved key and completed first check-in are required.", android.widget.Toast.LENGTH_LONG).show(); }
            }).show();
    }
}
