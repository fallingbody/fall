sed -i 's/if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {/if (android.os.Build.VERSION.SDK_INT >= 34) { \/\/ Android 14+/' /home/itzksv/Mine/my_codes/practice/project/fall/ldr_app/packages/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/GetUserMediaImpl.java

sed -i '/applicationContext.startService(serviceIntent);/d' /home/itzksv/Mine/my_codes/practice/project/fall/ldr_app/packages/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/GetUserMediaImpl.java

sed -i 's/} else {/} /' /home/itzksv/Mine/my_codes/practice/project/fall/ldr_app/packages/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/GetUserMediaImpl.java
