# kotlinx.serialization keeps its generated serializers through its own
# consumer rules; these cover the companion lookups on our model classes.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers @kotlinx.serialization.Serializable class xyz.chaosinc.cascade.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-dontwarn org.slf4j.**
