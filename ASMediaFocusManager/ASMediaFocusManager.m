//
//  ASMediaFocusManager.m
//  ASMediaFocusManager
//
//  Created by Philippe Converset on 11/12/12.
//  Copyright (c) 2012 AutreSphere. All rights reserved.
//

#import "ASMediaFocusManager.h"
#import "ASMediaFocusController.h"
#import <QuartzCore/QuartzCore.h>

static CGFloat const kAnimateElasticSizeRatio = 0.03;
static CGFloat const kAnimateElasticDurationRatio = 0.6;
static CGFloat const kAnimationDuration = 0.4;

@interface ASMediaFocusManager ()
// The media view being focused.
@property (nonatomic, strong) UIView *mediaView;
@property (nonatomic, strong) ASMediaFocusController *focusViewController;
@property (nonatomic) BOOL isZooming;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@end

@implementation ASMediaFocusManager

// Taken from https://github.com/rs/SDWebImage/blob/master/SDWebImage/SDWebImageDecoder.m
- (UIImage *)decodedImageWithImage:(UIImage *)image
{
    if (image.images) {
        // Do not decode animated images
        return image;
    }
    
    CGImageRef imageRef = image.CGImage;
    CGSize imageSize = CGSizeMake(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
    CGRect imageRect = (CGRect){.origin = CGPointZero, .size = imageSize};
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
    
    int infoMask = (bitmapInfo & kCGBitmapAlphaInfoMask);
    BOOL anyNonAlpha = (infoMask == kCGImageAlphaNone ||
                        infoMask == kCGImageAlphaNoneSkipFirst ||
                        infoMask == kCGImageAlphaNoneSkipLast);
    
    // CGBitmapContextCreate doesn't support kCGImageAlphaNone with RGB.
    // https://developer.apple.com/library/mac/#qa/qa1037/_index.html
    if (infoMask == kCGImageAlphaNone && CGColorSpaceGetNumberOfComponents(colorSpace) > 1) {
        // Unset the old alpha info.
        bitmapInfo &= ~kCGBitmapAlphaInfoMask;
        
        // Set noneSkipFirst.
        bitmapInfo |= kCGImageAlphaNoneSkipFirst;
    }
    // Some PNGs tell us they have alpha but only 3 components. Odd.
    else if (!anyNonAlpha && CGColorSpaceGetNumberOfComponents(colorSpace) == 3) {
        // Unset the old alpha info.
        bitmapInfo &= ~kCGBitmapAlphaInfoMask;
        bitmapInfo |= kCGImageAlphaPremultipliedFirst;
    }
    
    // It calculates the bytes-per-row based on the bitsPerComponent and width arguments.
    CGContextRef context = CGBitmapContextCreate(NULL,
                                                 imageSize.width,
                                                 imageSize.height,
                                                 CGImageGetBitsPerComponent(imageRef),
                                                 0,
                                                 colorSpace,
                                                 bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    
    // If failed, return undecompressed image
    if (!context) return image;
    
    CGContextDrawImage(context, imageRect, imageRef);
    CGImageRef decompressedImageRef = CGBitmapContextCreateImage(context);
    
    CGContextRelease(context);
    
    UIImage *decompressedImage = [UIImage imageWithCGImage:decompressedImageRef scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(decompressedImageRef);
    return decompressedImage;
}

- (id)init
{
    self = [super init];
    if(self)
    {
        self.animationDuration = kAnimationDuration;
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        self.elasticAnimation = YES;
        self.zoomEnabled = YES;
        self.isZooming = NO;
        self.gestureDisabledDuringZooming = YES;
        self.isDefocusingWithTap = NO;
    }
    
    return self;
}

- (void)installOnViews:(NSArray *)views
{
    for(UIView *view in views)
    {
        [self installOnView:view];
    }
}

- (void)installOnView:(UIView *)view
{
    UITapGestureRecognizer *tapGesture;
    
    tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleFocusGesture:)];
    [view addGestureRecognizer:tapGesture];
    view.userInteractionEnabled = YES;
}

- (void)installDefocusActionOnFocusViewController:(ASMediaFocusController *)focusViewController
{
    // We need the view to be loaded.
    if(focusViewController.view)
    {
        if(self.isDefocusingWithTap)
        {
            self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDefocusGesture:)];
            [focusViewController.view addGestureRecognizer:self.tapGesture];
        }
        else
        {
            [self setupAccessoryViewOnFocusViewController:focusViewController];
        }
    }
}

- (ASMediaFocusController *)focusViewControllerForView:(UIView *)mediaView
{
    ASMediaFocusController *viewController;
    UIImage *image;
    
    image = [self.delegate mediaFocusManager:self imageForView:mediaView];
    if(image == nil)
        return nil;
    
    viewController = [[ASMediaFocusController alloc] initWithNibName:nil bundle:nil];
    [self installDefocusActionOnFocusViewController:viewController];
    viewController.titleLabel.text = [self.delegate mediaFocusManager:self titleForView:mediaView];
    viewController.focusingImage = image;
    viewController.mainImageView.image = image;
    
    if ([self.delegate respondsToSelector:@selector(mediaFocusManager:mediaURLForView:)]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSURL *url;
            NSData *data;
            NSError *error = nil;
            
            url = [self.delegate mediaFocusManager:self mediaURLForView:mediaView];
            data = [NSData dataWithContentsOfURL:url options:0 error:&error];
            if(error != nil)
            {
                NSLog(@"Warning: Unable to load image at %@. %@", url, error);
            }
            else
            {
                UIImage *image;
                
                image = [[UIImage alloc] initWithData:data];
                image = [self decodedImageWithImage:image];
                dispatch_async(dispatch_get_main_queue(), ^{
                    viewController.mainImageView.image = image;
                });
            }
        });
    }
    else if ([self.delegate respondsToSelector:@selector(mediaFocusManager:mediaImageForView:)]) {
        UIImage *image = [self.delegate mediaFocusManager:self mediaImageForView:mediaView];
        viewController.mainImageView.image = image;
    }
    else {
        // raise exception if media source method is not implemented
        [NSException raise:@"Missing media method" format:@"One of the following delegate methods must be implemented:\n\n(NSURL *)mediaFocusManager:(ASMediaFocusManager *)mediaFocusManager mediaURLForView:(UIView *)view\n\n(UIImage *)mediaFocusManager:(ASMediaFocusManager *)mediaFocusManager mediaImageForView:(UIView *)view"];
    }
    
    return viewController;
}

- (CGRect)rectInsetsForRect:(CGRect)frame ratio:(CGFloat)ratio
{
    CGFloat dx;
    CGFloat dy;
    
    dx = frame.size.width*ratio;
    dy = frame.size.height*ratio;
    
    return CGRectInset(frame, dx, dy);
}

- (void)installZoomView
{
    if(self.zoomEnabled)
    {
        [self.focusViewController installZoomView];
        [self.tapGesture requireGestureRecognizerToFail:self.focusViewController.doubleTapGesture];
    }
}

- (void)uninstallZoomView
{
    if(self.zoomEnabled)
    {
        [self.focusViewController uninstallZoomView];
    }
}

- (void)setupAccessoryViewOnFocusViewController:(ASMediaFocusController *)focusViewController
{
    UIButton *doneButton;
    
    doneButton = [UIButton buttonWithType:UIButtonTypeCustom];
    doneButton.titleLabel.font = [UIFont fontWithName:kFontBold size:20.0];
    [doneButton setTitle:NSLocalizedString(@"Done", @"Done") forState:UIControlStateNormal];
    [doneButton addTarget:self action:@selector(handleDefocusGesture:) forControlEvents:UIControlEventTouchUpInside];
    doneButton.backgroundColor = [UIColor clearColor];
    [doneButton sizeToFit];
    doneButton.frame = CGRectMake(-100, [UIApplication sharedApplication].delegate.window.bounds.size.height - 46, doneButton.frame.size.width, doneButton.frame.size.height);
    doneButton.layer.borderWidth = 2;
    doneButton.layer.cornerRadius = 4;
    doneButton.layer.borderColor = [UIColor clearColor].CGColor;
    doneButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [focusViewController.contentView addSubview:doneButton];
    focusViewController.accessoryView = doneButton;
    
    doneButton.alpha = 0;
    [UIView animateWithDuration:0.5
                     animations:^{
                         doneButton.alpha = 1;
                     }];
}

#pragma mark - Gestures
- (void)handleFocusGesture:(UIGestureRecognizer *)gesture
{
    UIViewController *parentViewController;
    ASMediaFocusController *focusViewController;
    CGPoint center;
    UIView *mediaView;
    UIView *imageView;
    
    mediaView = gesture.view;
    focusViewController = [self focusViewControllerForView:mediaView];
    if(focusViewController == nil)
        return;
    
    self.focusViewController = focusViewController;
    self.mediaView = mediaView;
    parentViewController = [self.delegate parentViewControllerForMediaFocusManager:self];
    [parentViewController addChildViewController:focusViewController];
    [parentViewController.view addSubview:focusViewController.view];
    focusViewController.view.frame = parentViewController.view.bounds;
    
    imageView = focusViewController.mainImageView;
    center = [imageView.superview convertPoint:mediaView.center fromView:mediaView.superview];
    imageView.center = center;
    imageView.transform = mediaView.transform;
    imageView.bounds = mediaView.bounds;
    imageView.alpha = 0;
    
    self.isZooming = YES;
    
    [UIView animateWithDuration:self.animationDuration
                     animations:^{
                         CGRect frame;
                         CGRect initialFrame;
                         CGAffineTransform initialTransform;
                         
                         if (self.delegate && [self.delegate respondsToSelector:@selector(mediaFocusManagerWillAppear:)])
                         {
                             [self.delegate mediaFocusManagerWillAppear:self];
                         }
                         
                         frame = [self.delegate mediaFocusManager:self finalFrameforView:mediaView];
                         frame = (self.elasticAnimation?[self rectInsetsForRect:frame ratio:-kAnimateElasticSizeRatio]:frame);
                         
                         // Trick to keep the right animation on the image frame.
                         // The image frame shoud animate from its current frame to a final frame.
                         // The final frame is computed by taking care of a possible rotation regarding the current device orientation, done by calling updateOrientationAnimated.
                         // As this method changes the image frame, it also replaces the current animation on the image view, which is not wanted.
                         // Thus to recreate the right animation, the image frame is set back to its inital frame then to its final frame.
                         // This very last frame operation recreates the right frame animation.
                         initialTransform = imageView.transform;
                         imageView.transform = CGAffineTransformIdentity;
                         initialFrame = imageView.frame;
                         imageView.frame = frame;
                         [focusViewController updateOrientationAnimated:NO];
                         // This is the final image frame. No transform.
                         frame = imageView.frame;
                         // It must now be animated from its initial frame and transform.
                         imageView.frame = initialFrame;
                         imageView.transform = initialTransform;
                         imageView.transform = CGAffineTransformIdentity;
                         imageView.frame = frame;
                         focusViewController.view.backgroundColor = self.backgroundColor;
                         mediaView.alpha = 0;
                         imageView.alpha = 1;
                     }
                     completion:^(BOOL finished) {
                         [UIView animateWithDuration:(self.elasticAnimation?self.animationDuration*kAnimateElasticDurationRatio:0)
                                          animations:^{
                                              imageView.frame = focusViewController.contentView.bounds;
                                          }
                                          completion:^(BOOL finished) {
                                              [self installZoomView];
                                              self.isZooming = NO;
                                              
                                              if (self.delegate && [self.delegate respondsToSelector:@selector(mediaFocusManagerDidAppear:)])
                                              {
                                                  [self.delegate mediaFocusManagerDidAppear:self];
                                              }
                                          }];
                     }];
}

- (void)handleDefocusGesture:(UIGestureRecognizer *)gesture
{
    if (self.isZooming && self.gestureDisabledDuringZooming) return;
    
    UIView *contentView;
    CGRect __block bounds;
    
    [self uninstallZoomView];
    [self.focusViewController pinAccessoryViews];
    
    contentView = self.focusViewController.mainImageView;
    [UIView animateWithDuration:self.animationDuration
                     animations:^{
                         if (self.delegate && [self.delegate respondsToSelector:@selector(mediaFocusManagerWillDisappear:)])
                         {
                             [self.delegate mediaFocusManagerWillDisappear:self];
                         }
                         
                         self.focusViewController.contentView.transform = CGAffineTransformIdentity;
                         contentView.center = [contentView.superview convertPoint:self.mediaView.center fromView:self.mediaView.superview];
                         contentView.transform = self.mediaView.transform;
                         bounds = self.mediaView.bounds;
                         contentView.bounds = (self.elasticAnimation?[self rectInsetsForRect:bounds ratio:kAnimateElasticSizeRatio]:bounds);
                         self.focusViewController.view.backgroundColor = [UIColor clearColor];
                         self.focusViewController.accessoryView.alpha = 0;
                         self.focusViewController.titleLabel.alpha = 0;
                         self.focusViewController.contentView.alpha = 0;
                         self.mediaView.alpha = 1.0;
                     }
                     completion:^(BOOL finished) {
                         [UIView animateWithDuration:(self.elasticAnimation?self.animationDuration*kAnimateElasticDurationRatio:0)
                                          animations:^{
                                              if(self.elasticAnimation)
                                              {
                                                  contentView.bounds = bounds;
                                              }
                                          }
                                          completion:^(BOOL finished) {
                                              [self.focusViewController.view removeFromSuperview];
                                              [self.focusViewController removeFromParentViewController];
                                              self.focusViewController = nil;
                                              
                                              if (self.delegate && [self.delegate respondsToSelector:@selector(mediaFocusManagerDidDisappear:)])
                                              {
                                                  [self.delegate mediaFocusManagerDidDisappear:self];
                                              }
                                          }];
                     }];
}

@end
